"""Failure-path coverage without launching a simulator or operator service."""
from pathlib import Path
import json
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import smoke


class FailureConsoleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.evidence = Path(self.directory.name)
        self.result = self.evidence / 'result.xcresult'
        self.result.mkdir()
        self.raw_files = []

    def exporter(self, payloads):
        def export(arguments, **kwargs):
            raw = kwargs['stdout']
            self.raw_files.append(raw)
            self.assertEqual(kwargs['timeout'], smoke.CONSOLE_EXPORT_TIMEOUT)
            self.assertEqual(kwargs['stderr'], subprocess.DEVNULL)
            value = payloads[arguments[arguments.index('--type') + 1]]
            if isinstance(value, Exception):
                raise value
            if isinstance(value, int):
                return subprocess.CompletedProcess(arguments, value)
            raw.write(json.dumps(value).encode())
            return subprocess.CompletedProcess(arguments, 0)
        return export

    def retained(self):
        self.assertTrue(all(raw.closed for raw in self.raw_files))
        output = self.evidence / 'failure-console.log'
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        return output.read_text()

    def test_console_redacts_tokens_and_excludes_debugger_input(self):
        token = 'isolated_' + 'a' * 48
        other_token = 'isolated_' + 'b' * 48
        payload = {'items': [
            {'adaptorType': 'debugger', 'kind': 'output', 'content': 'private launch settings'},
            {'adaptorType': 'target', 'kind': 'input', 'content': 'private command'},
            {'adaptorType': 'target', 'kind': 'output', 'content': f'Pending send {token} {other_token}'},
        ]}
        with patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': payload})) as run:
            status = smoke.retain_failure_console(self.result, self.evidence, token)
        self.assertTrue(status.startswith('retained: console'))
        self.assertEqual(run.call_count, 1)
        text = self.retained()
        self.assertIn('Pending send <redacted> <redacted>', text)
        for secret in (token, other_token, 'private launch settings', 'private command'):
            self.assertNotIn(secret, text)

    def test_action_fallback_retains_only_test_output(self):
        action = {'commandInvocationDetails': {'commandDetails': 'secret environment'},
                  'attachments': [{'data': 'private binary'}],
                  'subsections': [{'testDetails': {'emittedOutput': 'app waiting for reply',
                                                  'runnablePath': 'private executable'}}]}
        with patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': 1, 'action': action})):
            status = smoke.retain_failure_console(self.result, self.evidence, '')
        self.assertTrue(status.startswith('retained: action'))
        text = self.retained()
        self.assertIn('app waiting for reply', text)
        self.assertNotIn('secret', text)
        self.assertNotIn('private', text)

    def test_tail_is_bounded_and_redacted_before_byte_truncation(self):
        token = 'isolated_' + 'c' * 48
        output = 'discarded\n' * 600 + ('🙂' * 20000) + token + '\nlast useful failure'
        payload = {'items': [{'kind': 'output', 'content': output}]}
        with patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': payload})):
            smoke.retain_failure_console(self.result, self.evidence, token)
        text = self.retained()
        self.assertLessEqual(len(text.encode()), smoke.CONSOLE_TEXT_LIMIT)
        self.assertLessEqual(len(text.splitlines()), smoke.CONSOLE_LINE_LIMIT + 1)
        self.assertTrue(text.endswith('<redacted>\nlast useful failure'))
        self.assertNotIn('discarded', text)
        self.assertNotIn('isolated_', text)

    def test_oversized_or_malformed_export_records_unavailability(self):
        payload = {'items': [{'content': 'too much text'}]}
        with patch.object(smoke, 'CONSOLE_RAW_LIMIT', 8), \
                patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': payload, 'action': payload})):
            status = smoke.retain_failure_console(self.result, self.evidence, '')
        self.assertIn('size limit', status)
        self.assertNotIn('too much text', self.retained())
        with patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': [], 'action': []})):
            status = smoke.retain_failure_console(self.result, self.evidence, '')
        self.assertTrue(status.startswith('unavailable:'))
        self.assertNotIn('Traceback', self.retained())

    def test_missing_bundle_is_reported_without_export(self):
        with patch.object(smoke.subprocess, 'run') as run:
            status = smoke.retain_failure_console(self.evidence / 'missing', self.evidence, '')
        run.assert_not_called()
        self.assertEqual(status, 'unavailable: result bundle missing')
        self.assertIn(status, self.retained())

    def test_export_timeout_and_write_failure_preserve_original_test_error(self):
        original = subprocess.CalledProcessError(65, ['xcodebuild'])
        timeout = subprocess.TimeoutExpired(['private-token'], smoke.CONSOLE_EXPORT_TIMEOUT)
        with patch.object(smoke, 'run', side_effect=original), \
                patch.object(smoke.subprocess, 'run', side_effect=self.exporter({'console': timeout, 'action': timeout})), \
                patch.object(Path, 'write_text', side_effect=OSError('private-token')), \
                patch('builtins.print') as output:
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                smoke.run_native_tests(Path('private.xctestrun'), 'owned-simulator', self.evidence, 'private-token')
        self.assertIs(raised.exception, original)
        self.assertTrue(all(raw.closed for raw in self.raw_files))
        self.assertNotIn('private-token', str(output.call_args_list))

    def test_successful_tests_do_not_export_diagnostics(self):
        with patch.object(smoke, 'run'), patch.object(smoke, 'retain_failure_console') as retain:
            smoke.run_native_tests(Path('private.xctestrun'), 'owned-simulator', self.evidence, 'private-token')
        retain.assert_not_called()
        self.assertFalse((self.evidence / 'failure-console.log').exists())

    def test_unexpected_diagnostic_exception_preserves_original_test_error(self):
        original = subprocess.CalledProcessError(65, ['xcodebuild'])
        with patch.object(smoke, 'run', side_effect=original), \
                patch.object(smoke, 'retain_failure_console', side_effect=RuntimeError('private-token')), \
                patch('builtins.print') as output:
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                smoke.run_native_tests(Path('private.xctestrun'), 'owned-simulator', self.evidence, 'private-token')
        self.assertIs(raised.exception, original)
        self.assertEqual(raised.exception.returncode, 65)
        output.assert_called_once_with('Failure console: unavailable: diagnostic collection failed')
        self.assertNotIn('private-token', str(output.call_args_list))


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
