import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from common import atomic, canonical, digest
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
            start.assert_called_once()
            self.assertIn("dieter-deploy@first.service", start.call_args.args[0])
        self.assertEqual(first, same)
        (self.incoming / "settings.json").write_text('{"tls":"existing"}')
        with self.assertRaisesRegex(ValueError, "different inputs"):
            self.admit()
        self.assertEqual(reconstructed.status("first")["state"], "admitted")
        reconstructed.transition("first", "committed")
        (self.incoming / "settings.json").write_text('{"tls":"managed"}')
        with patch("host.run") as start:
            reconstructed.admit("first", self.incoming)
            start.assert_not_called()

    def test_reboot_resumes_only_nonterminal_operations(self):
        self.admit("one")
        self.admit("two")
        self.host.transition("two", "committed")
        with patch("host.run") as start:
            Host(self.policy).resume()
            self.assertEqual(start.call_count, 1)
            self.assertIn("dieter-deploy@one.service", start.call_args.args[0])

    def test_rollback_readmits_only_a_previously_accepted_signed_release(self):
        self.admit("old")
        with self.assertRaisesRegex(ValueError, "accepted"):
            self.host.rollback("rollback", "old")
        self.host.transition("old", "committed")
        with patch("host.run"):
            result = self.host.rollback("rollback", "old")
        self.assertEqual(result["state"], "admitted")
        self.assertEqual(result["requestSHA256"], self.host.status("old")["requestSHA256"])
        self.assertEqual(self.host.status("old")["state"], "committed")

    def test_deployment_key_cannot_change_host_mounts_identity_or_routes(self):
        selection = json.loads((Path(__file__).resolve().parents[1] / "profiles/example.settings.json").read_text())
        self.host.config.update(selection)
        self.host.validate_selection(selection, self.incoming)
        for field, bad in (("caddyData", "/etc"), ("caddyConfig", "/root"), ("stateVolume", "unrelated-volume"),
                           ("publicIPv4", "192.0.2.99"), ("turnHost", "other.example.com"), ("allowedUserIDs", [99]),
                           ("legacyHosts", ["unreviewed.example.com"])):
            with self.assertRaises(ValueError, msg=field):
                self.host.validate_selection(dict(selection, **{field: bad}), self.incoming)
        selection["legacyHosts"] = ["legacy.example.com"]
        self.host.config["legacyHosts"] = selection["legacyHosts"]
        path = self.incoming / "legacy.caddy"
        path.write_text("reviewed routes")
        self.host.config["legacyFragmentSHA256"] = digest(path)
        self.host.validate_selection(selection, self.incoming)
        path.write_text("unreviewed routes")
        with self.assertRaisesRegex(ValueError, "fragment"):
            self.host.validate_selection(selection, self.incoming)

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

    def test_rollback_waits_for_recreated_processes_to_become_ready(self):
        with patch.object(self.host, "health", side_effect=[ConnectionError("starting"), None]) as health, patch("host.time.sleep"):
            self.host.wait_health({})
            self.assertEqual(health.call_count, 2)
        with patch.object(self.host, "health", side_effect=ConnectionError("unavailable")):
            with self.assertRaises(ConnectionError):
                self.host.wait_health({}, timeout=0)

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
