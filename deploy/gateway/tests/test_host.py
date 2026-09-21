import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from common import atomic, canonical
from host import Host
from bundle import ARCHIVE, MANIFEST, SIGNATURE


class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.policy = self.root / "policy.json"
        self.policy.write_text(json.dumps({"installRoot": str(self.root / "opt"), "configRoot": str(self.root / "etc"),
            "stateRoot": str(self.root / "state"), "runtimeRoot": str(self.root / "run"), "project": "fixture",
            "backupCommand": ["/fixture/backup"], "readinessTimeoutSeconds": 20}))
        self.host = Host(self.policy)
        self.host.initialize()
        self.incoming = self.root / "incoming"
        self.incoming.mkdir()
        for name in (ARCHIVE, MANIFEST, SIGNATURE):
            (self.incoming / name).write_text("fixture")
        (self.incoming / "settings.json").write_text('{"tls":"managed"}')

    def admit(self, operation="first"):
        with patch("host.run"):
            return self.host.admit(operation, self.incoming)

    def test_admission_survives_observer_and_is_idempotent(self):
        first = self.admit()
        reconstructed = Host(self.policy)
        with patch("host.run") as start:
            same = reconstructed.admit("first", self.incoming)
            start.assert_not_called()
        self.assertEqual(first, same)
        (self.incoming / "settings.json").write_text('{"tls":"existing"}')
        with self.assertRaisesRegex(ValueError, "different inputs"):
            self.admit()
        self.assertEqual(reconstructed.status("first")["state"], "admitted")

    def test_reboot_resumes_only_nonterminal_operations(self):
        self.admit("one")
        self.admit("two")
        self.host.transition("two", "committed")
        with patch("host.run") as start:
            Host(self.policy).resume()
            self.assertEqual(start.call_count, 1)
            self.assertIn("dieter-deploy@one.service", start.call_args.args[0])

    def test_interrupted_activation_rolls_back_instead_of_replaying(self):
        self.admit()
        previous = self.host.install / "releases/baseline"
        (previous / "public").mkdir(parents=True)
        atomic(previous / "public/settings.json", "{}")
        self.host.transition("first", "checking", previousRelease=str(previous))
        with patch.object(self.host, "activate") as activate, patch.object(self.host, "health"):
            result = self.host.execute("first")
            activate.assert_called_once_with(previous)
        self.assertEqual(result["state"], "rolled_back")
        self.assertEqual((self.host.install / "current").resolve(), previous)
        with patch.object(self.host, "activate") as activate:
            self.host.execute("first")
            activate.assert_not_called()

    def test_failed_rollback_is_explicit(self):
        self.admit()
        self.host.transition("first", "activating", previousRelease=str(self.root / "previous"))
        with patch.object(self.host, "activate", side_effect=RuntimeError("do not expose private output")):
            result = self.host.execute("first")
        self.assertEqual(result["state"], "failed")
        self.assertTrue(result["rollbackFailed"])
        self.assertNotIn("private output", json.dumps(result))

    def test_readiness_binds_to_operation_and_requires_authentication_and_payload(self):
        self.admit()
        self.host.transition("first", "checking", sourceRevision="a"*40)
        report = self.root / "report.json"
        evidence = {"requestSHA256": self.host.status("first")["requestSHA256"], "sourceRevision": "a"*40,
                    "gatewayAuthenticated": True, "daemonAuthenticated": True, "unauthenticatedRejected": True,
                    "turnPayloadTransports": ["udp", "tcp", "tls"]}
        for field, bad in (("sourceRevision", "b"*40), ("gatewayAuthenticated", False),
                           ("daemonAuthenticated", False), ("turnPayloadTransports", ["udp", "tcp"]),
                           ("unauthenticatedRejected", False)):
            atomic(report, canonical(dict(evidence, **{field: bad})))
            with self.assertRaises(ValueError):
                self.host.accept("first", report)
            self.assertFalse((self.host.operation("first") / "readiness.json").exists())
        atomic(report, canonical(evidence))
        self.assertTrue(self.host.accept("first", report)["readinessReceived"])


if __name__ == "__main__":
    unittest.main()
