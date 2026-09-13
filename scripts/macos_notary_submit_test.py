import contextlib
import io
import subprocess
import unittest
from unittest.mock import patch

from macos_notary_submit import submit


class NotarizationTests(unittest.TestCase):
    def invoke(self, code, response):
        with patch("macos_notary_submit.subprocess.run", return_value=subprocess.CompletedProcess(
            [], code, stdout=response, stderr="private diagnostic"
        )) as command, contextlib.redirect_stdout(io.StringIO()):
            submit("artifact.pkg", "private-key.p8", "KEY-ID", "ISSUER")
        return command.call_args.args[0]

    def test_accepted_submission_waits_and_requests_json(self):
        command = self.invoke(0, '{"status":"Accepted"}')
        self.assertIn("--wait", command)
        self.assertEqual(command[-2:], ["--output-format", "json"])

    def test_rejection_and_unfinished_status_cannot_publish_even_with_zero_exit(self):
        for status in ("Invalid", "Rejected", "In Progress", "accepted", ""):
            with self.subTest(status=status), self.assertRaisesRegex(RuntimeError, "not Accepted"):
                self.invoke(0, '{"status":"' + status + '"}')

    def test_failure_and_malformed_output_cannot_publish(self):
        for code, response in [(1, '{"status":"Accepted"}'), (0, "not json"), (0, "[]"), (0, "null")]:
            with self.subTest(code=code, response=response), self.assertRaises(RuntimeError) as result:
                self.invoke(code, response)
            self.assertNotIn("private", str(result.exception))


if __name__ == "__main__":
    unittest.main()
