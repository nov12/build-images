#!/usr/bin/env python3
"""Keep every tag's current manifest and its dependencies; prune only orphans."""

import argparse
import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

ACCEPT = ', '.join((
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
))


def request(url, headers, method='GET'):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(
                urllib.request.Request(url, headers=headers, method=method), timeout=30
            ) as response:
                return response.read(), response.headers
        except (urllib.error.URLError, TimeoutError) as error:
            transient = not isinstance(error, urllib.error.HTTPError) or error.code in (429, 500, 502, 503, 504)
            if method != 'GET' or not transient or attempt == 3:
                raise RuntimeError(f'{method} {url} failed: {error}') from error
            time.sleep(2 ** attempt)


class Package:
    def __init__(self, owner, name, token):
        self.owner, self.name, self.token = owner, name, token
        owner_type = self.api(f'/users/{urllib.parse.quote(owner, safe="")}')['type']
        prefix = 'orgs' if owner_type == 'Organization' else 'users'
        self.path = f'/{prefix}/{urllib.parse.quote(owner, safe="")}/packages/container/{urllib.parse.quote(name, safe="")}'
        repository = os.environ.get('GITHUB_REPOSITORY')
        if repository and self.api(self.path).get('repository', {}).get('full_name') != repository:
            raise RuntimeError('Package belongs to a different repository')
        credentials = base64.b64encode(f'{os.environ.get("GITHUB_ACTOR", owner)}:{token}'.encode()).decode()
        query = urllib.parse.urlencode({'service': 'ghcr.io', 'scope': f'repository:{owner.lower()}/{name}:pull'})
        raw, _ = request('https://ghcr.io/token?' + query, {'Authorization': 'Basic ' + credentials})
        self.registry_token = json.loads(raw)['token']

    def api(self, path, method='GET'):
        raw, _ = request('https://api.github.com' + path, {
            'Authorization': 'Bearer ' + self.token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        }, method)
        return json.loads(raw) if raw else None

    def versions(self):
        result = []
        page = 1
        while True:
            batch = self.api(f'{self.path}/versions?per_page=100&page={page}')
            result.extend(batch)
            if len(batch) < 100:
                return result
            page += 1

    def manifest(self, reference):
        raw, headers = request(
            f'https://ghcr.io/v2/{self.owner.lower()}/{self.name}/manifests/{urllib.parse.quote(reference, safe=":")}',
            {'Authorization': 'Bearer ' + self.registry_token, 'Accept': ACCEPT},
        )
        digest = 'sha256:' + hashlib.sha256(raw).hexdigest()
        if headers.get('Docker-Content-Digest') != digest:
            raise RuntimeError('Registry manifest digest verification failed')
        if reference.startswith('sha256:') and digest != reference:
            raise RuntimeError('Registry returned a different manifest')
        return digest, json.loads(raw)

    def delete(self, version):
        current = self.api(f'{self.path}/versions/{version["id"]}')
        if current['name'] != version['name'] or current['metadata']['container']['tags']:
            raise RuntimeError('Deletion candidate changed; refusing to delete it')
        self.api(f'{self.path}/versions/{version["id"]}', 'DELETE')


def tag_map(versions):
    result = {}
    for version in versions:
        for tag in version['metadata']['container']['tags']:
            if tag in result:
                raise RuntimeError('Tag listing changed during pagination')
            result[tag] = version['name']
    return result


def prune(package, apply=False):
    versions = package.versions()
    tags = tag_map(versions)
    if not tags:
        raise RuntimeError('No tagged manifests; refusing to prune the package')
    # Every tag is a root, including historical version tags. Never pick only latest.
    protected = set()
    pending = list(set(tags.values()))
    while pending:
        reference = pending.pop()
        if reference in protected:
            continue
        digest, manifest = package.manifest(reference)
        if digest != reference:
            raise RuntimeError('Manifest reference changed')
        protected.add(digest)
        pending.extend(item['digest'] for item in manifest.get('manifests', []))
        if manifest.get('subject'):
            pending.append(manifest['subject']['digest'])
    candidates = [v for v in versions if not v['metadata']['container']['tags'] and v['name'] not in protected]
    deleted = []
    if apply:
        for version in candidates:
            if tag_map(package.versions()) != tags:
                raise RuntimeError('Tags changed; stopping cleanup')
            package.delete(version)
            deleted.append(version['id'])
            print(f'Deleted orphan {package.name}@{version["name"]}', flush=True)
        if tag_map(package.versions()) != tags:
            raise RuntimeError('Tags changed during cleanup')
    # Verify each public tag still resolves to the same content, even in dry runs.
    for tag, expected in sorted(tags.items()):
        actual, _ = package.manifest(tag)
        if actual != expected:
            raise RuntimeError(f'Tag {tag} changed during cleanup')
    return {'package': package.name, 'tags': tags, 'protected': sorted(protected),
            'candidates': [v['id'] for v in candidates], 'deleted': deleted}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('owner')
    parser.add_argument('package')
    parser.add_argument('--apply', action='store_true', help='Delete untagged, unreferenced versions')
    args = parser.parse_args()
    package = Package(args.owner, args.package, os.environ['GH_TOKEN'])
    result = prune(package, args.apply)
    print(json.dumps(result, indent=2), flush=True)
    if args.apply and os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(f'Preserved all {len(result["tags"])} tags of {args.package}; removed {len(result["deleted"])} unreferenced versions.\n')


if __name__ == '__main__':
    main()
