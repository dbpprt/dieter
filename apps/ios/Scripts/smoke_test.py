"""Failure-path coverage without launching a simulator or operator service."""
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import smoke


class SmokeLifecycleTests(unittest.TestCase):
    def test_readiness_requires_marker_and_child_stays_alive(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'private.log'
            log.write_text('DIETER_ISOLATED_TOKEN=private-token\n')
            child = Mock()
            child.poll.return_value = None
            with patch.object(smoke.time, 'monotonic', side_effect=[0, 0, 61]), \
                    patch.object(smoke.time, 'sleep'):
                with self.assertRaisesRegex(RuntimeError, 'within 60 seconds'):
                    smoke.wait_for_gateway(child, log)
            log.write_text('DIETER_ISOLATED_TOKEN=private-token\nREADY\n')
            self.assertEqual(smoke.wait_for_gateway(child, log)['DIETER_ISOLATED_TOKEN'], 'private-token')

    def test_exited_child_reports_failure_without_exposing_log(self):
        child = Mock(returncode=7)
        child.poll.return_value = 7
        with self.assertRaisesRegex(RuntimeError, 'exited 7'):
            smoke.wait_for_gateway(child, Path('/no/log/needed'))

    def test_stuck_gateway_escalates_only_its_owned_group(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired('private-command', 15),
                                  subprocess.TimeoutExpired('private-command', 5), 0]
        with patch.object(smoke.os, 'killpg') as kill:
            smoke.stop_gateway(child)
        child.send_signal.assert_called_once_with(signal.SIGINT)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(12345, signal.SIGTERM),
                                              unittest.mock.call(12345, signal.SIGKILL)])
        self.assertEqual([call.kwargs['timeout'] for call in child.wait.call_args_list], [15, 5, 5])

    def test_cleanup_failures_do_not_skip_other_resources_or_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            raw = evidence / '.gateway-private.log'
            raw.write_text('DIETER_ISOLATED_TOKEN=private-token\nrequest used private-token\n')
            stream = raw.open()
            failure = subprocess.TimeoutExpired(['private-token'], 5)
            with patch.object(smoke, 'stop_gateway', side_effect=failure), \
                    patch.object(smoke.subprocess, 'run', side_effect=[failure, 0]) as run:
                errors = smoke.cleanup_resources(Mock(), stream, 'owned-simulator', evidence)
            self.assertEqual(len(errors), 2)
            self.assertTrue(stream.closed)
            self.assertFalse(raw.exists())
            self.assertNotIn('private-token', (evidence / 'gateway.log').read_text())
            self.assertNotIn('private-token', (evidence / 'cleanup.log').read_text())
            self.assertEqual([call.args[0][2] for call in run.call_args_list], ['shutdown', 'delete'])
            self.assertTrue(all(call.kwargs['timeout'] == 30 for call in run.call_args_list))

    def test_raw_log_is_removed_even_when_retention_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory) / '.gateway-private.log'
            raw.write_text('DIETER_ISOLATED_TOKEN=private-token\n')
            with patch.object(Path, 'write_text', side_effect=OSError('cannot write')):
                with self.assertRaises(OSError):
                    smoke.retain_gateway_log(raw, Path(directory) / 'gateway.log')
            self.assertFalse(raw.exists())

    def test_finished_gateway_is_not_signaled(self):
        child = Mock()
        child.poll.return_value = 0
        smoke.stop_gateway(child)
        child.send_signal.assert_not_called()

    def test_unwritable_cleanup_log_does_not_mask_primary_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(smoke, 'stop_gateway', side_effect=TimeoutError()), \
                    patch.object(Path, 'write_text', side_effect=OSError()):
                errors = smoke.cleanup_resources(Mock(), None, None, Path(directory))
            self.assertEqual(errors, ['stop isolated gateway: TimeoutError',
                                      'write cleanup diagnostics: OSError'])


if __name__ == '__main__':
    unittest.main()
