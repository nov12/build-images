#!/usr/bin/env python3
"""Resolve an official GitHub release without relying on package registry tags."""

import argparse
import json
import re
import subprocess


def select_release(releases, tag_prefix='v', include_prereleases=False):
    pattern = re.compile(re.escape(tag_prefix) + r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?')
    candidates = [
        release for release in releases
        if release.get('draft') is False
        and (include_prereleases or release.get('prerelease') is False)
        and release.get('published_at')
        and pattern.fullmatch(release.get('tag_name', ''))
    ]
    if not candidates:
        raise ValueError('No published release matches the requested tag prefix and release policy')
    # GitHub lists releases by creation time; a release can be published later.
    return max(candidates, key=lambda release: (release['published_at'], release.get('id', 0)))


def resolve_release(repository, tag_prefix='v', include_prereleases=False):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Expected a GitHub owner/repository')
    endpoint = f'repos/{repository}/releases'
    if include_prereleases:
        command = ['gh', 'api', '--paginate', '--slurp', endpoint + '?per_page=100']
    else:
        command = ['gh', 'api', endpoint + '/latest']
    response = json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)
    releases = [release for page in response for release in page] if include_prereleases else [response]
    return select_release(releases, tag_prefix, include_prereleases)['tag_name']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository')
    parser.add_argument('--tag-prefix', default='v')
    parser.add_argument('--include-prereleases', action='store_true')
    args = parser.parse_args()
    try:
        print(resolve_release(args.repository, args.tag_prefix, args.include_prereleases))
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release resolution failed: {error}\n')


if __name__ == '__main__':
    main()
