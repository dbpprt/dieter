import datetime
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import fleet_release_watch as watcher
import macos_auto_update as updater

NOW = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
FEED = 'https://updates.example.test/dieter-release.json'


def release(tag='v0.4.300'):
    return {'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': [
        {'name': name, 'browser_download_url': f'https://github.com/dbpprt/dieter/releases/download/{tag}/{name}'}
        for name in ('SHA256SUMS', 'dieter-darwin-arm64.tar.gz', 'Dieter-macOS-arm64.zip')]}


class FleetWatcherTests(unittest.TestCase):
    def test_publish_and_two_clients_use_same_selection_without_github_polling(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'release.json'
            with patch.object(watcher, 'fetch', return_value=json.dumps(release()).encode()) as fetch:
                watcher.publish(output, NOW)
                fetch.assert_called_once_with(updater.RELEASES, 2 * 1024 * 1024)
            with patch.object(updater, 'fetch', return_value=output.read_bytes()) as fetch:
                for _ in range(2):
                    self.assertEqual(updater.selected_release(FEED, NOW)['tag_name'], 'v0.4.300')
                self.assertEqual([c.args[0] for c in fetch.call_args_list], [FEED, FEED])

    def test_network_failure_and_downgrade_keep_previous_plan(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'release.json'
            with patch.object(watcher, 'fetch', return_value=json.dumps(release()).encode()):
                watcher.publish(output, NOW)
            before = output.read_bytes()
            for result in (OSError('offline'), json.dumps(release('v0.4.299')).encode()):
                kwargs = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
                with patch.object(watcher, 'fetch', **kwargs), self.assertRaises(Exception):
                    watcher.publish(output, NOW)
                self.assertEqual(output.read_bytes(), before)

    def test_offline_client_does_not_fall_back_to_independent_selection(self):
        with patch.object(updater, 'fetch', side_effect=OSError('offline')) as fetch:
            with self.assertRaises(OSError):
                updater.selected_release(FEED, NOW)
            fetch.assert_called_once_with(FEED, 2 * 1024 * 1024)

    def test_expired_future_and_naive_timestamps_rejected(self):
        for timestamp in (NOW - datetime.timedelta(hours=37), NOW + datetime.timedelta(minutes=1), NOW.replace(tzinfo=None)):
            plan = {'protocol': 1, 'checkedAt': timestamp.isoformat(), 'release': release()}
            with patch.object(updater, 'fetch', return_value=json.dumps(plan)), self.assertRaises(updater.Deferred):
                updater.selected_release(FEED, NOW)

    def test_wrong_assets_and_prereleases_are_rejected(self):
        for mutate in (lambda r: r.update(prerelease=True),
                       lambda r: r['assets'][0].update(browser_download_url='https://evil.test/code'),
                       lambda r: r['assets'].append(r['assets'][0])):
            r = release()
            mutate(r)
            with tempfile.TemporaryDirectory() as root, patch.object(watcher, 'fetch', return_value=json.dumps(r)):
                output = Path(root) / 'release.json'
                with self.assertRaises(updater.Deferred):
                    watcher.publish(output, NOW)
                self.assertFalse(output.exists())
            plan = {'protocol': 1, 'checkedAt': NOW.isoformat(), 'release': r}
            with patch.object(updater, 'fetch', return_value=json.dumps(plan)), self.assertRaises(updater.Deferred):
                updater.selected_release(FEED, NOW)

    def test_non_https_feed_rejected_before_request(self):
        for url in ('http://updates.test/feed', 'https://user:secret@updates.test/feed', 'file:///tmp/feed'):
            with patch.object(updater, 'fetch') as fetch, self.assertRaises(updater.Deferred):
                updater.selected_release(url, NOW)
            fetch.assert_not_called()

    def test_managed_schedule_retries_without_second_release_watcher(self):
        agent = updater.launch_agent(Path('/updater'), Path('/config'), '/python', managed=True)
        self.assertEqual(agent['StartInterval'], 900)
        self.assertNotIn('StartCalendarInterval', agent)
        self.assertTrue(agent['RunAtLoad'])


if __name__ == '__main__':
    unittest.main()
