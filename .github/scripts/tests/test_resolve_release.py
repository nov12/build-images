import importlib.util
import json
import pathlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('resolve_release', pathlib.Path(__file__).parents[1] / 'resolve-release.py')
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)


def release(tag, published, **fields):
    return {'tag_name': tag, 'published_at': published, 'draft': False, 'prerelease': True, **fields}


class ReleaseTest(unittest.TestCase):
    def test_deepseek_follows_newest_published_release_including_rc(self):
        releases = [release('dsh-v0.2.2-rc.1', '2026-11-04T13:07:14Z'),
                    release('dsh-v0.2.2-rc.3', '2026-11-13T07:56:55Z'),
                    release('dsh-v0.2.2-rc.2', '2026-11-11T11:33:06Z')]
        self.assertEqual(resolver.select_release(releases, 'dsh-v', True)['tag_name'], 'dsh-v0.2.2-rc.3')

    def test_ignores_drafts_unpublished_and_other_products(self):
        releases = [release('dsh-v0.2.2-rc.3', '2026-11-13T07:56:55Z'),
                    release('dsh-v0.3.0', '2026-11-14T00:00:00Z', draft=True),
                    release('dsh-v0.4.0', None),
                    release('sdk-v9.0.0', '2026-11-15T00:00:00Z'),
                    release('dsh-vnot-a-version', '2026-11-16T00:00:00Z')]
        self.assertEqual(resolver.select_release(releases, 'dsh-v', True)['tag_name'], 'dsh-v0.2.2-rc.3')

    def test_stable_policy_keeps_other_images_off_prereleases(self):
        releases = [release('v1.0.0', '2026-11-01T00:00:00Z', prerelease=False),
                    release('v1.1.0-rc.1', '2026-11-02T00:00:00Z')]
        self.assertEqual(resolver.select_release(releases)['tag_name'], 'v1.0.0')

    def test_future_stable_deepseek_release_is_accepted(self):
        releases = [release('dsh-v0.2.2-rc.3', '2026-11-13T07:56:55Z'),
                    release('dsh-v0.2.2', '2026-11-14T00:00:00Z', prerelease=False)]
        self.assertEqual(resolver.select_release(releases, 'dsh-v', True)['tag_name'], 'dsh-v0.2.2')

    def test_no_matching_release_fails_instead_of_falling_back(self):
        with self.assertRaises(ValueError):
            resolver.select_release([release('sdk-v9.0.0', '2026-11-15T00:00:00Z')], 'dsh-v', True)

    @patch.object(resolver.subprocess, 'run')
    def test_prerelease_resolution_reads_all_pages(self, run):
        run.return_value.stdout = json.dumps([
            [release('dsh-v0.2.2-rc.1', '2026-11-04T00:00:00Z')],
            [release('dsh-v0.2.2-rc.3', '2026-11-13T00:00:00Z')],
        ])
        self.assertEqual(resolver.resolve_release('deepseek-ai/deepseek-harness', 'dsh-v', True), 'dsh-v0.2.2-rc.3')

    @patch.object(resolver.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['gh', 'api']))
    def test_api_failure_propagates_without_registry_fallback(self, run):
        with self.assertRaises(subprocess.CalledProcessError):
            resolver.resolve_release('deepseek-ai/deepseek-harness', 'dsh-v', True)


if __name__ == '__main__':
    unittest.main()
