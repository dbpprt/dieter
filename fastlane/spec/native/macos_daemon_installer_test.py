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

from fastlane.lib.dieter.native.installer import build, preinstall_script, release_number


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.bundle = self.source / "DieterDaemon.app/Contents/MacOS"
        self.bundle.mkdir(parents=True)
        for name in ("dieter", "dieter-capture"):
            path = self.bundle / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        (self.source / "LICENSE").write_text("Test license\n")
        self.output = self.root / "dist/dieter.pkg"

    def run_preinstall(self, version="1.2.3"):
        script = self.root / "preinstall"
        script.write_text(preinstall_script(version))
        volume = self.root / "volume"
        volume.mkdir(exist_ok=True)
        return subprocess.run(
            ["/bin/sh", str(script), "package.pkg", "/", str(volume)],
            capture_output=True,
            text=True,
        )

    def test_reinstall_refused_without_modifying_existing_daemon(self):
        existing = self.root / "volume/usr/local/libexec/dieter/1.2.3"
        existing.mkdir(parents=True)
        executable = existing / "dieter"
        executable.write_bytes(b"existing running daemon")
        self.assertNotEqual(self.run_preinstall().returncode, 0)
        self.assertEqual(executable.read_bytes(), b"existing running daemon")

    def test_each_symlink_ancestor_is_refused(self):
        for relative in (
            "usr",
            "usr/local",
            "usr/local/libexec",
            "usr/local/libexec/dieter",
            "usr/local/libexec/dieter/1.2.3",
        ):
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
        (self.bundle / "dieter").unlink()
        (self.bundle / "dieter").symlink_to(self.bundle / "dieter-capture")
        with (
            patch("fastlane.lib.dieter.native.installer.run") as command,
            self.assertRaises(RuntimeError),
        ):
            build(self.source, self.output, "1.2.3")
        command.assert_not_called()

    @unittest.skipUnless(platform.system() == "Darwin", "pkgbuild requires macOS")
    def test_real_pkg_has_only_versioned_payload_and_non_mutating_preinstall(self):
        with contextlib.redirect_stdout(io.StringIO()):
            build(self.source, self.output, "v1.2.3")
        expanded = self.root / "expanded"
        subprocess.run(
            ["pkgutil", "--expand-full", str(self.output), str(expanded)],
            check=True,
            capture_output=True,
        )
        metadata = ET.parse(expanded / "PackageInfo").getroot()
        self.assertEqual(metadata.get("identifier"), "com.dbpprt.dieter.daemon.v1.2.3")
        self.assertEqual(metadata.get("version"), "1.2.3")
        self.assertEqual(metadata.get("install-location"), "/usr/local/libexec/dieter/1.2.3")
        payload = expanded / "Payload"
        files = {str(path.relative_to(payload)) for path in payload.rglob("*") if path.is_file()}
        self.assertEqual(
            files,
            {
                "LICENSE",
                "INSTALL.txt",
                "DieterDaemon.app/Contents/MacOS/dieter",
                "DieterDaemon.app/Contents/MacOS/dieter-capture",
            },
        )
        bom = subprocess.run(
            ["lsbom", "-s", str(expanded / "Bom")], check=True, capture_output=True, text=True
        ).stdout.splitlines()
        # pkgbuild may add AppleDouble entries beside payload files and directories.
        self.assertEqual(
            {name for name in bom if not Path(name).name.startswith("._")},
            {
                ".",
                "./LICENSE",
                "./INSTALL.txt",
                "./DieterDaemon.app",
                "./DieterDaemon.app/Contents",
                "./DieterDaemon.app/Contents/MacOS",
                "./DieterDaemon.app/Contents/MacOS/dieter",
                "./DieterDaemon.app/Contents/MacOS/dieter-capture",
            },
        )
        self.assertEqual({path.name for path in (expanded / "Scripts").iterdir()}, {"preinstall"})
        self.assertEqual((expanded / "Scripts/preinstall").read_text(), preinstall_script("1.2.3"))
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            build(self.source, self.output, "v1.2.3")


if __name__ == "__main__":
    unittest.main()
