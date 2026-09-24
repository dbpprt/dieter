import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

import macos_auto_update as updater


class SafeUpdaterTests(unittest.TestCase):
    def test_twice_daily_schedule_and_no_busy_retry_loop(self):
        agent = updater.launch_agent(Path('/tmp/updater.py'), Path('/tmp/config'), '/usr/bin/python3')
        self.assertEqual(agent['StartCalendarInterval'], [{'Hour': 9, 'Minute': 0}, {'Hour': 21, 'Minute': 0}])
        self.assertNotIn('KeepAlive', agent)

    def test_codesign_uses_inline_requirement(self):
        with patch.object(updater, 'run') as command:
            updater.signed('/candidate', 'com.dbpprt.dieter.daemon')
        args = command.call_args.args
        self.assertTrue(args[args.index('-R') + 1].startswith('=identifier '))

    def test_candidate_without_probe_or_with_wrong_api_is_rejected(self):
        for result in ('unknown command', '{"protocol":1,"version":"0.4.300","apiVersion":"2"}',
                       '{"protocol":1,"version":"0.4.299","apiVersion":"1"}'):
            with patch.object(updater, 'run', return_value=result), self.assertRaises(updater.Deferred):
                updater.probe('/candidate', '/data', '0.4.300', '1')
        with patch.object(updater, 'run', return_value='{"protocol":1,"version":"0.4.300","apiVersion":"1"}'):
            updater.probe('/candidate', '/data', '0.4.300', '1')

    def test_snapshot_preserves_chats_and_does_not_recurse_into_backups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'data'
            root.mkdir()
            (root / 'chats').mkdir()
            (root / 'chats/one').write_bytes(b'original conversation')
            (root / 'auto-update').mkdir()
            (root / 'worktree-link').symlink_to('/outside/repository')
            backup = root / 'auto-update/backup'
            updater.snapshot(root, backup)
            self.assertEqual((backup / 'chats/one').read_bytes(), b'original conversation')
            self.assertFalse((backup / 'auto-update').exists())
            self.assertTrue((backup / 'worktree-link').is_symlink())

    def make_updater(self, directory):
        instance = updater.Updater.__new__(updater.Updater)
        instance.root = Path(directory) / 'data'
        instance.root.mkdir()
        instance.state = instance.root / 'auto-update'
        instance.state.mkdir()
        (instance.root / 'runtime').mkdir()
        instance.runtime = Path(directory) / 'service'
        instance.runtime.mkdir()
        (instance.runtime / 'version').write_text('old')
        instance.app = Path(directory) / 'Dieter.app'
        (instance.app / 'Contents').mkdir(parents=True)
        (instance.app / 'Contents/version').write_text('old')
        instance.fixed = True
        instance.target = 'test-service'
        instance.stop = Mock()
        instance.start = Mock()
        instance.healthy = Mock()
        return instance

    def test_partial_backup_is_never_restored(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            backup = instance.state / 'backup'
            (backup / 'runtime').mkdir(parents=True)
            updater.write_json(instance.state / 'transaction.json', {'backup': str(backup), 'previous': '0.4.1'})
            with patch.object(updater.subprocess, 'run', return_value=Mock(returncode=1)):
                with self.assertRaises(updater.Deferred):
                    instance.recover()
            self.assertEqual((instance.runtime / 'version').read_text(), 'old')
            instance.start.assert_called_once()
            self.assertFalse((instance.state / 'transaction.json').exists())

    def test_crash_recovery_restores_binaries_but_never_overwrites_new_chats(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            backup = instance.state / 'backup'
            (backup / 'runtime').mkdir(parents=True)
            (backup / 'runtime/version').write_text('old')
            (backup / 'data').mkdir()
            (backup / 'Contents').mkdir()
            (backup / 'Contents/version').write_text('old')
            (instance.root / 'chat').write_text('new messages after upgrade')
            (instance.runtime / 'version').write_text('broken new')
            (instance.app / 'Contents/version').write_text('new')
            updater.write_json(instance.state / 'transaction.json', {'backup': str(backup), 'previous': '0.4.1', 'backupsComplete': True})
            with patch.object(updater.subprocess, 'run', return_value=Mock(returncode=1)), patch.object(updater, 'app_running', return_value=False):
                with self.assertRaises(updater.Deferred):
                    instance.recover()
            self.assertEqual((instance.runtime / 'version').read_text(), 'old')
            self.assertEqual((instance.app / 'Contents/version').read_text(), 'old')
            self.assertEqual((instance.root / 'chat').read_text(), 'new messages after upgrade')
            self.assertTrue(backup.exists())
            instance.healthy.assert_called_once_with('0.4.1')

    def test_active_agent_defers_before_stopping_service(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            with patch.object(updater, 'run', side_effect=['{"projects":[]}', '[{"runtime":"running"}]']):
                with self.assertRaises(updater.Deferred):
                    instance.idle()
            instance.stop.assert_not_called()

    def test_active_card_in_another_project_is_not_missed(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            responses = ['{"projects":[{"id":"one"},{"id":"two"}]}',
                         '[]', '[]', '[]', '[{"runtime":"running"}]']
            with patch.object(updater, 'run', side_effect=responses) as command:
                with self.assertRaises(updater.Deferred):
                    instance.idle()
            self.assertIn('two', command.call_args.args)
            instance.stop.assert_not_called()

    def test_failed_activation_keeps_chats_and_restores_both_binaries(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            (instance.root / 'chat').write_text('keep every message')
            new_app = Path(directory) / 'new.app'
            (new_app / 'Contents').mkdir(parents=True)
            (new_app / 'Contents/version').write_text('new')
            instance.healthy.side_effect = [updater.Deferred('failed readiness'), None]
            with patch.object(updater, 'run', return_value=''), \
                 patch.object(updater, 'signed'), \
                 patch.object(updater, 'app_running', return_value=False), \
                 patch.object(updater.subprocess, 'run', return_value=Mock(returncode=0)), \
                 patch.object(updater.shutil, 'disk_usage', return_value=Mock(free=10**12)):
                with self.assertRaises(updater.Deferred):
                    instance.activate(Path('/candidate'), new_app, '0.4.2', '0.4.1')
            self.assertEqual((instance.root / 'chat').read_text(), 'keep every message')
            self.assertEqual((instance.app / 'Contents/version').read_text(), 'old')
            self.assertEqual((instance.runtime / 'version').read_text(), 'old')
            backups = list((instance.state / 'backups').iterdir())
            self.assertEqual(len(backups), 1)
            self.assertEqual((backups[0] / 'data/chat').read_text(), 'keep every message')
            self.assertFalse((instance.state / 'transaction.json').exists())

    def test_manual_prefix_preserves_unrelated_tools_during_backup_and_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            instance.fixed = False
            (instance.runtime / 'bin').mkdir()
            for name in ('dieter', 'dieter-capture'):
                (instance.runtime / 'bin' / name).write_text('old ' + name)
            unrelated = instance.runtime / 'bin/other-tool'
            unrelated.write_text('do not touch')
            backup = instance.state / 'manual-backup'
            instance.backup_runtime(backup)
            self.assertFalse((backup / 'bin/other-tool').exists())
            (instance.runtime / 'bin/dieter').write_text('broken candidate')
            instance.replace_manual_pair(backup / 'bin')
            self.assertEqual((instance.runtime / 'bin/dieter').read_text(), 'old dieter')
            self.assertEqual(unrelated.read_text(), 'do not touch')

    def test_manual_activation_updates_only_dieter_and_app(self):
        with tempfile.TemporaryDirectory() as directory:
            instance = self.make_updater(directory)
            instance.fixed = False
            (instance.runtime / 'bin').mkdir()
            candidate = Path(directory) / 'release'
            candidate.mkdir()
            for name in ('dieter', 'dieter-capture'):
                (instance.runtime / 'bin' / name).write_text('old')
                (candidate / name).write_text('new')
            unrelated = instance.runtime / 'bin/other-tool'
            unrelated.write_text('unchanged')
            (instance.root / 'chat').write_text('saved conversation')
            new_app = Path(directory) / 'new.app'
            (new_app / 'Contents').mkdir(parents=True)
            (new_app / 'Contents/version').write_text('new')
            with patch.object(updater, 'signed'), \
                 patch.object(updater, 'app_running', return_value=False), \
                 patch.object(updater.shutil, 'disk_usage', return_value=Mock(free=10**12)):
                instance.activate(candidate, new_app, '0.4.2', '0.4.1')
            self.assertEqual((instance.runtime / 'bin/dieter').read_text(), 'new')
            self.assertEqual((instance.app / 'Contents/version').read_text(), 'new')
            self.assertEqual(unrelated.read_text(), 'unchanged')
            self.assertEqual((instance.root / 'chat').read_text(), 'saved conversation')
            instance.healthy.assert_called_once_with('0.4.2')
            self.assertFalse((instance.state / 'transaction.json').exists())

    def test_overlapping_runs_are_excluded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lock'
            with updater.exclusive(path):
                with self.assertRaises(BlockingIOError):
                    with updater.exclusive(path):
                        self.fail('second updater acquired lock')


if __name__ == '__main__':
    unittest.main()
