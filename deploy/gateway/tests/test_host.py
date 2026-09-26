import json
import shutil
import sqlite3
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from common import atomic, canonical, digest, pointer, read_json, validate_gateway_health
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
        space = patch("host.shutil.disk_usage", return_value=shutil._ntuple_diskusage(8 << 30, 0, 8 << 30))
        space.start()
        self.addCleanup(space.stop)
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

    def test_admission_rejects_low_disk_before_creating_an_operation(self):
        with patch("host.shutil.disk_usage", return_value=shutil._ntuple_diskusage(8 << 30, 7 << 30, 1 << 30)):
            with self.assertRaisesRegex(ValueError, "insufficient deployment staging space"):
                self.admit()
        self.assertFalse(self.host.operation("first").exists())

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

    def test_backup_recovers_active_routes_during_root_reviewed_hostname_change(self):
        from recover import inspect_snapshot
        selection = read_json(Path(__file__).resolve().parents[1] / "profiles/example.settings.json")
        for key in ("installRoot", "configRoot", "runtimeRoot"):
            selection[key] = self.host.config[key]
        for key in ("caddyData", "caddyConfig"):
            selection[key] = str(self.root / key)
            Path(selection[key]).mkdir()
        self.host.config.update(selection, controllerLink="/usr/local/lib/dieter-deploy")
        self.host.config["turnHost"] = "next-turn.example.com"
        self.host.config["gatewayHost"] = "next-gateway.example.com"
        self.host.config["gatewayAliases"] = [selection["gatewayHost"]]
        self.host.config["legacyHosts"] = ["retired.example.com"]
        atomic(self.policy, canonical(self.host.config))
        original_policy = self.policy.read_bytes()
        release = self.host.install / "releases/accepted"
        (release / "public").mkdir(parents=True)
        atomic(release / "public/settings.json", canonical(selection))
        image = "registry/gateway@sha256:" + "a" * 64
        atomic(release / "public/compose.json", canonical({"services": {"dieter-gateway": {"image": image}}}))
        pointer(self.host.install / "current", release)
        source = self.root / "volume"
        (source / "signing").mkdir(parents=True)
        for name in ("gateway-ed25519.pem", "daemon-ca-ed25519.pem", "daemon-ca.pem"):
            (source / "signing" / name).write_text("fixture identity")
        with sqlite3.connect(source / "gateway.db") as db:
            db.execute("PRAGMA user_version=1")
        archived = []

        def external(argv, **kwargs):
            if argv[:3] == ["docker", "image", "inspect"]:
                return canonical([{"Id": "sha256:" + "b" * 64, "Size": 1}])
            if argv[:3] == ["docker", "image", "save"]:
                Path(argv[argv.index("--output") + 1]).write_bytes(b"fixture image archive")
                return b""
            self.assertEqual(argv[0], "/fixture/backup")
            # Exercise the actual clean-host recovery contract on the prepared
            # snapshot, including SQLite integrity and archived image mapping.
            _, _, policy, active, _, _ = inspect_snapshot(argv[-1])
            self.assertEqual(policy["turnHost"], selection["turnHost"])
            self.assertEqual(policy["gatewayHost"], selection["gatewayHost"])
            self.assertEqual(policy["gatewayIdentityHost"], selection["gatewayHost"])
            self.assertEqual(policy["gatewayAliases"], [])
            self.assertEqual(policy["legacyHosts"], active["legacyHosts"])
            archived.append(policy)
            return canonical({"snapshotID": "fixture", "offHost": True})

        with patch.object(self.host, "volume", return_value=source), patch("host.run", side_effect=external):
            result = self.host.backup(dict(selection, turnHost="next-turn.example.com"), "rename")
        self.assertTrue(result["offHost"])
        self.assertEqual(len(archived), 1)
        self.assertEqual(self.policy.read_bytes(), original_policy)
        self.assertEqual(self.host.config["turnHost"], "next-turn.example.com")

    def test_rollback_waits_for_recreated_processes_to_become_ready(self):
        with patch.object(self.host, "health", side_effect=[ConnectionError("starting"), None]) as health, patch("host.time.sleep"):
            self.host.wait_health({})
            self.assertEqual(health.call_count, 2)
        with patch.object(self.host, "health", side_effect=ConnectionError("unavailable")):
            with self.assertRaises(ConnectionError):
                self.host.wait_health({}, timeout=0)

    def test_readiness_binds_to_operation_and_requires_authentication_and_payload(self):
        self.admit()
        policy = {"minimumClientVersion": "0.4.20", "minimumDaemonVersion": "0.4.19"}
        self.host.transition("first", "checking", sourceRevision="a"*40, compatibilityPolicy=policy)
        report = self.root / "report.json"
        evidence = {"requestSHA256": self.host.status("first")["requestSHA256"], "sourceRevision": "a"*40,
                    "gatewayAuthenticated": True, "daemonAuthenticated": True, "unauthenticatedRejected": True,
                    "turnPayloadTransports": ["udp", "tcp", "tls"], "compatibilityPolicy": policy}
        for field, bad in (("sourceRevision", "b"*40), ("gatewayAuthenticated", False),
                           ("daemonAuthenticated", False), ("turnPayloadTransports", ["udp", "tcp"]),
                           ("unauthenticatedRejected", False),
                           ("compatibilityPolicy", {"minimumClientVersion": "0.4.18", "minimumDaemonVersion": "0.4.19"}),
                           ("compatibilityPolicy", None)):
            atomic(report, canonical(dict(evidence, **{field: bad})))
            with self.assertRaises(ValueError):
                self.host.accept("first", report)
            self.assertFalse((self.host.operation("first") / "readiness.json").exists())
        atomic(report, canonical(evidence))
        self.assertTrue(self.host.accept("first", report)["readinessReceived"])

    def test_health_uses_selected_release_and_policy_including_rollback(self):
        for version in ("0.4.20", "0.5.0-dev.4+abc"):
            policy = {'minimumClientVersion': '0.4.18', 'minimumDaemonVersion': '0.4.19'}
            manifest = {'sourceRevision': 'a'*40, 'releaseVersion': version, 'compatibilityPolicy': policy}
            health = {'service': 'dieter-gateway', 'status': 'ok', 'version': version, 'revision': 'a'*40, **policy}
            validate_gateway_health(health, manifest)
            with self.assertRaisesRegex(ValueError, 'release differs'):
                validate_gateway_health(dict(health, version='0.6.0'), manifest)
            with self.assertRaisesRegex(ValueError, 'compatibility policy differs'):
                validate_gateway_health(dict(health, minimumClientVersion='0.4.17'), manifest)
            with self.assertRaisesRegex(ValueError, 'source revision'):
                validate_gateway_health(dict(health, revision='b'*40), manifest)
            with self.assertRaisesRegex(ValueError, 'not healthy'):
                validate_gateway_health(dict(health, status='failed'), manifest)
            with self.assertRaisesRegex(ValueError, 'missing or invalid'):
                validate_gateway_health(dict(health, version=''), manifest)


if __name__ == "__main__":
    unittest.main()
