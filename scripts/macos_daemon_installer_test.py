import base64
import contextlib
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

from macos_daemon_installer import build, preinstall_script, release_number, sign


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for name in ("dieter", "dieter-capture"):
            path = self.source / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        (self.source / "LICENSE").write_text("Test license\n")
        self.output = self.root / "dist/dieter.pkg"

    def run_preinstall(self, version="1.2.3"):
        script = self.root / "preinstall"
        script.write_text(preinstall_script(version))
        volume = self.root / "volume"
        volume.mkdir(exist_ok=True)
        return subprocess.run(["/bin/sh", str(script), "package.pkg", "/", str(volume)],
                              capture_output=True, text=True)

    def test_reinstall_refused_without_modifying_existing_daemon(self):
        existing = self.root / "volume/usr/local/libexec/dieter/1.2.3"
        existing.mkdir(parents=True)
        executable = existing / "dieter"
        executable.write_bytes(b"existing running daemon")
        self.assertNotEqual(self.run_preinstall().returncode, 0)
        self.assertEqual(executable.read_bytes(), b"existing running daemon")

    def test_each_symlink_ancestor_is_refused(self):
        for relative in ("usr", "usr/local", "usr/local/libexec", "usr/local/libexec/dieter",
                         "usr/local/libexec/dieter/1.2.3"):
            with self.subTest(relative=relative):
                volume = self.root / "volume"
                if volume.exists():
                    shutil.rmtree(volume)
                link = volume / relative
                link.parent.mkdir(parents=True)
                link.symlink_to(self.source, target_is_directory=True)
                self.assertNotEqual(self.run_preinstall().returncode, 0)

    def test_new_version_can_install_next_to_old_without_changing_it(self):
        old = self.root / "volume/usr/local/libexec/dieter/1.2.2"
        old.mkdir(parents=True)
        (old / "dieter").write_text("old daemon")
        self.assertEqual(self.run_preinstall().returncode, 0)
        self.assertEqual((old / "dieter").read_text(), "old daemon")
        self.assertFalse((old.parent / "1.2.3").exists())

    def test_unsafe_versions_and_staging_links_are_rejected_before_pkgbuild(self):
        for version in ("", "../1.2.3", "1.2.3/../../bin", "1.2.3;bad", "1.2.3-beta"):
            with self.subTest(version=version), self.assertRaises(RuntimeError):
                release_number(version)
        self.assertEqual(release_number("v1.2.3"), "1.2.3")
        (self.source / "dieter").unlink()
        (self.source / "dieter").symlink_to(self.source / "dieter-capture")
        with patch("macos_daemon_installer.run") as command, self.assertRaises(RuntimeError):
            build(self.source, self.output, "1.2.3")
        command.assert_not_called()

    @unittest.skipUnless(platform.system() == "Darwin", "pkgbuild requires macOS")
    def test_real_pkg_has_only_versioned_payload_and_non_mutating_preinstall(self):
        with contextlib.redirect_stdout(io.StringIO()):
            build(self.source, self.output, "v1.2.3")
        expanded = self.root / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(self.output), str(expanded)], check=True,
                       capture_output=True)
        metadata = ET.parse(expanded / "PackageInfo").getroot()
        self.assertEqual(metadata.get("identifier"), "com.dbpprt.dieter.daemon.v1.2.3")
        self.assertEqual(metadata.get("version"), "1.2.3")
        self.assertEqual(metadata.get("install-location"), "/usr/local/libexec/dieter/1.2.3")
        payload = expanded / "Payload"
        files = {str(path.relative_to(payload)) for path in payload.rglob("*") if path.is_file()}
        self.assertEqual(files, {"dieter", "dieter-capture", "LICENSE", "INSTALL.txt"})
        bom = subprocess.run(["lsbom", "-s", str(expanded / "Bom")], check=True,
                             capture_output=True, text=True).stdout.splitlines()
        # pkgbuild may add AppleDouble entries for the four payload files.
        self.assertEqual({name for name in bom if not name.startswith("./._")},
                         {".", "./dieter", "./dieter-capture", "./LICENSE", "./INSTALL.txt"})
        self.assertTrue(all(name == "." or Path(name).parent == Path(".") for name in bom))
        self.assertEqual({path.name for path in (expanded / "Scripts").iterdir()}, {"preinstall"})
        self.assertEqual((expanded / "Scripts/preinstall").read_text(), preinstall_script("1.2.3"))
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            build(self.source, self.output, "v1.2.3")

    def test_signing_requires_ci_before_any_keychain_access(self):
        with patch.dict(os.environ, {}, clear=True), patch("macos_daemon_installer.run") as command:
            with self.assertRaisesRegex(RuntimeError, "CI-only"):
                sign(self.output)
        command.assert_not_called()

    def test_rejected_notarization_preserves_unsigned_output_and_cleans_keys(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"unsigned installer")
        credentials = {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(self.root),
                       "INSTALLER_CERTIFICATE_BASE64": base64.b64encode(b"p12 fixture").decode(),
                       "INSTALLER_CERTIFICATE_PASSWORD": "password fixture",
                       "NOTARY_KEY_BASE64": base64.b64encode(b"p8 fixture").decode(),
                       "NOTARY_KEY_ID": "key", "NOTARY_ISSUER_ID": "issuer"}
        calls = []

        def fake_run(*args, **kwargs):
            calls.append(args)
            if args == ("security", "list-keychains", "-d", "user"):
                return '    "/Users/fixture/Library/Keychains/login.keychain-db"\n    "/Library/Keychains/Fixture Keychain.keychain-db"\n'
            if args[:2] == ("security", "find-identity"):
                return '1) 1234 "Developer ID Installer: Fixture (TEAM)"'
            if args[0] == "productsign":
                Path(args[-1]).write_bytes(b"signed installer")
            return ""

        with patch.dict(os.environ, credentials), patch("macos_daemon_installer.run", side_effect=fake_run), \
                patch("macos_daemon_installer.submit", side_effect=RuntimeError("not Accepted")), \
                patch("macos_daemon_installer.subprocess.run") as cleanup:
            with self.assertRaisesRegex(RuntimeError, "not Accepted"):
                sign(self.output)
        self.assertEqual(self.output.read_bytes(), b"unsigned installer")
        self.assertEqual(cleanup.call_count, 2)
        self.assertEqual(cleanup.call_args_list[0].args[0],
                         ["security", "list-keychains", "-d", "user", "-s",
                          "/Users/fixture/Library/Keychains/login.keychain-db",
                          "/Library/Keychains/Fixture Keychain.keychain-db"])
        self.assertEqual(cleanup.call_args_list[1].args[0][:2], ["security", "delete-keychain"])
        search_update = next(call for call in calls if call[:5] == ("security", "list-keychains", "-d", "user", "-s"))
        self.assertTrue(search_update[5].endswith("/signing.keychain-db"))
        self.assertEqual(list(search_update[6:]), cleanup.call_args_list[0].args[0][5:])
        self.assertEqual(list(self.root.glob("dieter-installer-signing-*")), [])
        self.assertFalse(any("stapler" in call for call in calls))

    def test_publish_waits_for_stapling_signature_and_gatekeeper_validation(self):
        self.output.parent.mkdir()
        credentials = {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(self.root),
                       "INSTALLER_CERTIFICATE_BASE64": base64.b64encode(b"p12 fixture").decode(),
                       "INSTALLER_CERTIFICATE_PASSWORD": "password fixture",
                       "NOTARY_KEY_BASE64": base64.b64encode(b"p8 fixture").decode(),
                       "NOTARY_KEY_ID": "key", "NOTARY_ISSUER_ID": "issuer"}
        for failure in ("search-list", "import", "signature", "staple", "validate", "gatekeeper", None):
            with self.subTest(failure=failure):
                self.output.write_bytes(b"unsigned installer")
                calls = []

                def fake_run(*args, **kwargs):
                    self.assertEqual(self.output.read_bytes(), b"unsigned installer")
                    calls.append(args)
                    if args == ("security", "list-keychains", "-d", "user"):
                        return '"/Users/fixture/Library/Keychains/login.keychain-db"'
                    if args[:2] == ("security", "find-identity"):
                        return '1) 1234 "Developer ID Installer: Fixture (TEAM)"'
                    if args[0] == "productsign":
                        Path(args[-1]).write_bytes(b"signed installer")
                    if ((failure == "search-list" and args[:5] == ("security", "list-keychains", "-d", "user", "-s"))
                            or (failure == "import" and args[:2] == ("security", "import"))
                            or (failure == "signature" and args[0] == "pkgutil")
                            or (failure in ("staple", "validate") and args[:3] == ("xcrun", "stapler", failure))
                            or (failure == "gatekeeper" and args[0] == "spctl")):
                        raise RuntimeError("verification failed")
                    if args[:3] == ("xcrun", "stapler", "staple"):
                        Path(args[-1]).write_bytes(b"signed installer with ticket")
                    return ""

                with patch.dict(os.environ, credentials), patch("macos_daemon_installer.run", side_effect=fake_run), \
                        patch("macos_daemon_installer.submit"), patch("macos_daemon_installer.subprocess.run") as cleanup, \
                        contextlib.redirect_stdout(io.StringIO()):
                    if failure:
                        with self.assertRaisesRegex(RuntimeError, "verification failed"):
                            sign(self.output)
                        self.assertEqual(self.output.read_bytes(), b"unsigned installer")
                    else:
                        sign(self.output)
                        self.assertEqual(self.output.read_bytes(), b"signed installer with ticket")
                        self.assertEqual(sum(call[0] == "pkgutil" for call in calls), 2)
                        self.assertEqual(calls[-1][:4], ("spctl", "--assess", "--type", "install"))
                self.assertEqual(cleanup.call_args_list[0].args[0],
                                 ["security", "list-keychains", "-d", "user", "-s",
                                  "/Users/fixture/Library/Keychains/login.keychain-db"])
                self.assertEqual(cleanup.call_args_list[1].args[0][:2], ["security", "delete-keychain"])
                self.assertEqual(list(self.root.glob("dieter-installer-signing-*")), [])


if __name__ == "__main__":
    unittest.main()
