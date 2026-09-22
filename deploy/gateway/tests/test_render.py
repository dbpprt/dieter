import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from common import ROOT, read_json
from render import render, secrets, settings


class RenderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.settings = read_json(ROOT / "profiles/example.settings.json")
        self.private = {"githubClientID": "test-id", "githubClientSecret": "x$\"\\=/ café",
                        "authSecret": "ab" * 32, "turnSharedSecret": "x$\"\\=/ café" * 4}
        self.secret_file = self.root / "secrets.json"
        self.secret_file.write_text(json.dumps(self.private))
        self.secret_file.chmod(0o600)

    def rendered(self):
        return render(self.settings, secrets(self.secret_file), "ghcr.io/dbpprt/dieter-gateway@sha256:" + "a" * 64, "test", self.root / "out")

    def test_secret_bytes_and_public_separation(self):
        out = self.rendered()
        env = dict(line.split("=", 1) for line in (out / "private/gateway.env").read_text().splitlines())
        self.assertEqual(env["DIETER_GITHUB_CLIENT_SECRET"], self.private["githubClientSecret"])
        self.assertEqual(bytes.fromhex(env["DIETER_RTC_TURN_SECRET"]), self.private["turnSharedSecret"].encode())
        self.assertIn("static-auth-secret=" + self.private["turnSharedSecret"], (out / "private/turnserver.conf").read_text())
        for path in (out / "public").iterdir():
            for secret in self.private.values():
                self.assertNotIn(secret, path.read_text())
        self.assertEqual((out / "private").stat().st_mode & 0o777, 0o700)
        self.assertEqual((out / "private/gateway.env").stat().st_mode & 0o777, 0o600)

    def test_environment_contract(self):
        out = self.rendered()
        env = (out / "private/gateway.env").read_text()
        for field in ("DIETER_PUBLIC_URL", "DIETER_AUTH_SECRET", "DIETER_GITHUB_ALLOWED_USER_IDS"):
            self.assertIn(field + "=", env)
        compose = read_json(out / "public/compose.json")
        self.assertTrue(compose["volumes"]["gateway-state"]["external"])
        gateway = compose["services"]["dieter-gateway"]
        self.assertEqual(gateway["user"], "100:101")
        self.assertEqual(gateway["env_file"][0]["format"], "raw")
        self.assertTrue(gateway["read_only"])
        for service in compose["services"].values():
            self.assertIn("@sha256:", service["image"])
            self.assertEqual(service["network_mode"], "host")
            self.assertIn("mem_limit", service)

    def test_unknown_settings_and_duplicate_keys_fail(self):
        self.settings["unused"] = True
        with self.assertRaises(ValueError):
            settings(self.settings)
        path = self.root / "duplicate.json"
        path.write_text('{"x":1,"x":2}')
        with self.assertRaises(ValueError):
            read_json(path)

    def test_invalid_secrets_fail_without_echo(self):
        for bad in ("line\nbreak", "line\rbreak", "null\0byte"):
            for field in self.private:
                value = dict(self.private, **{field: bad})
                self.secret_file.write_text(json.dumps(value))
                with self.assertRaises(ValueError) as error:
                    secrets(self.secret_file)
                self.assertNotIn(bad, str(error.exception))
        self.secret_file.chmod(0o644)
        with self.assertRaises(ValueError):
            secrets(self.secret_file)

    def test_existing_tls_has_no_mux_and_keeps_tcp_udp(self):
        self.settings["tls"] = "existing"
        out = self.rendered()
        self.assertNotIn("haproxy", read_json(out / "public/compose.json")["services"])
        self.assertNotIn("turns:", (out / "private/gateway.env").read_text())
        self.assertIn("protocols tls1.3", (out / "public/Caddyfile").read_text())
        self.assertIn("no-tcp-relay", (out / "private/turnserver.conf").read_text())
        self.assertNotIn("no-tcp\n", (out / "private/turnserver.conf").read_text())

    def test_two_ip_does_not_need_haproxy(self):
        self.settings.update(topology="two-ip", turnIPv4="203.0.113.11")
        out = self.rendered()
        self.assertNotIn("haproxy", read_json(out / "public/compose.json")["services"])
        self.assertIn("tls-listening-port=443", (out / "private/turnserver.conf").read_text())

    def test_bandwidth_reservations_cover_declared_allocations(self):
        turn = self.settings["turn"]
        turn["bpsCapacity"] = 12500000
        with self.assertRaisesRegex(ValueError, "reservation pool"):
            settings(self.settings)
        turn["bpsCapacity"] = turn["maxBps"] * turn["totalQuota"]
        self.assertEqual(settings(self.settings)["turn"]["bpsCapacity"], 320000000)
        turn["bpsCapacity"] -= 1
        with self.assertRaisesRegex(ValueError, "reservation pool"):
            settings(self.settings)

    def test_unsafe_hosts_paths_and_quota_fail(self):
        for key, value in (("gatewayHost", "x.example.com\nadmin off"), ("configRoot", "/etc/../tmp"),
                           ("publicIPv4", "127.0.0.1"), ("allowedUserIDs", [])):
            config = copy.deepcopy(self.settings)
            config[key] = value
            with self.assertRaises(ValueError):
                settings(config)
        self.settings["turn"]["totalQuota"] = 1024
        with self.assertRaises(ValueError):
            settings(self.settings)


if __name__ == "__main__":
    unittest.main()
