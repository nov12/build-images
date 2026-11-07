import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('prune_images', pathlib.Path(__file__).parents[1] / 'prune-images.py')
pruner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pruner)


def version(identifier, digest, tags=()):
    return {'id': identifier, 'name': digest, 'metadata': {'container': {'tags': list(tags)}}}


class Package:
    name = 'test-image'

    def __init__(self):
        self.items = [version(1, 'new-index', ['latest', 'v2']), version(2, 'new-amd64'),
                      version(3, 'new-arm64'), version(4, 'old-index', ['v1']),
                      version(5, 'old-amd64'), version(6, 'shared-arm64'),
                      version(7, 'replaced-index'), version(8, 'orphan')]
        self.manifests = {
            'new-index': {'manifests': [{'digest': 'new-amd64'}, {'digest': 'new-arm64'}]},
            'old-index': {'manifests': [{'digest': 'old-amd64'}, {'digest': 'shared-arm64'}]},
        }
        self.deleted = []
        self.calls = 0

    def versions(self):
        self.calls += 1
        return copy.deepcopy(self.items)

    def manifest(self, reference):
        digest = pruner.tag_map(self.items).get(reference, reference)
        return digest, self.manifests.get(digest, {})

    def delete(self, item):
        assert not item['metadata']['container']['tags']
        self.deleted.append(item['id'])
        self.items = [v for v in self.items if v['id'] != item['id']]


class RetentionTest(unittest.TestCase):
    def test_preserves_every_tag_and_both_architectures(self):
        package = Package()
        before = pruner.tag_map(package.items)
        result = pruner.prune(package, apply=True)
        self.assertEqual(package.deleted, [7, 8])
        self.assertEqual(result['tags'], before)
        self.assertEqual(pruner.tag_map(package.items), before)
        self.assertEqual({v['id'] for v in package.items}, {1, 2, 3, 4, 5, 6})

    def test_dry_run_does_not_delete(self):
        package = Package()
        self.assertEqual(pruner.prune(package)['candidates'], [7, 8])
        self.assertEqual(package.deleted, [])

    def test_no_tags_refuses_deletion(self):
        package = Package()
        for item in package.items:
            item['metadata']['container']['tags'] = []
        with self.assertRaises(RuntimeError):
            pruner.prune(package, apply=True)
        self.assertEqual(package.deleted, [])

    def test_incomplete_graph_refuses_deletion(self):
        package = Package()
        original = package.manifest
        def manifest(reference):
            if reference == 'new-arm64':
                raise RuntimeError('Manifest unavailable')
            return original(reference)
        package.manifest = manifest
        with self.assertRaises(RuntimeError):
            pruner.prune(package, apply=True)
        self.assertEqual(package.deleted, [])

    def test_tag_moves_before_deletion_stops_cleanup(self):
        package = Package()
        original = package.versions
        def versions():
            items = original()
            if package.calls > 1:
                items[0]['metadata']['container']['tags'].remove('latest')
                items[-1]['metadata']['container']['tags'].append('latest')
            return items
        package.versions = versions
        with self.assertRaises(RuntimeError):
            pruner.prune(package, apply=True)
        self.assertEqual(package.deleted, [])

    def test_tagged_deletion_candidate_is_rejected(self):
        package = pruner.Package.__new__(pruner.Package)
        package.path = '/test-package'
        calls = []
        def api(path, method='GET'):
            calls.append(method)
            return version(8, 'orphan', ['new-tag'])
        package.api = api
        with self.assertRaises(RuntimeError):
            package.delete(version(8, 'orphan'))
        self.assertEqual(calls, ['GET'])

    def test_all_version_pages_are_read(self):
        package = pruner.Package.__new__(pruner.Package)
        package.path = '/test-package'
        pages = [[version(i, str(i)) for i in range(100)], [version(100, 'last')]]
        calls = []
        def api(path):
            calls.append(path)
            return pages[len(calls) - 1]
        package.api = api
        self.assertEqual(len(package.versions()), 101)
        self.assertTrue(calls[-1].endswith('page=2'))

    def test_nested_index_and_subject_are_preserved(self):
        package = Package()
        package.manifests['new-arm64'] = {'manifests': [{'digest': 'orphan'}], 'subject': {'digest': 'replaced-index'}}
        self.assertEqual(pruner.prune(package, apply=True)['deleted'], [])


if __name__ == '__main__':
    unittest.main()
