import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from fastlane.lib.dieter.native import mac_bundle as mac_bundle


class MacBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dieter package with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.products = self.root / "compiled products"
        self.calls = []
        for source, target in mac_bundle.entries(self.root, self.products):
            if source.suffix in {".framework", ".bundle"} or source.name == "PaletteIcons":
                source.mkdir(parents=True, exist_ok=True)
                (source / "resource with spaces").write_text("content")
            else:
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(plistlib.dumps({"DieterReleaseVersion": "0.0.0"}) if source.suffix == ".plist" else b"content")
        for path in ["fastlane/lib/dieter/native/mac_bundle.py", "fastlane/lib/dieter/platforms/mac.rb", "apps/mac/scripts/verify-bundle.sh"]:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("implementation")

    def record(self, argv, **kwargs):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, 0)

    def package(self, **kwargs):
        return mac_bundle.package(self.root, self.products, "test-identity", run=self.record, **kwargs)

    def test_unchanged_package_does_not_copy_or_sign(self):
        bundle = self.package(version="1.2.3")
        before = (bundle / "Contents/MacOS/DieterMac").stat()
        self.calls.clear()
        self.package(version="1.2.3")
        self.assertFalse(any(call[0] == "codesign" for call in self.calls))
        self.assertEqual(before.st_ino, (bundle / "Contents/MacOS/DieterMac").stat().st_ino)
        self.assertEqual("1.2.3", plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["DieterReleaseVersion"])

    def test_removed_resources_and_changed_version_replace_complete_tree(self):
        icon = self.root / "apps/mac/Resources/PaletteIcons/removed.png"
        icon.write_text("old")
        bundle = self.package(version="1.0.0")
        icon.unlink()
        self.package(version="2.0.0")
        self.assertFalse((bundle / "Contents/Resources/PaletteIcons/removed.png").exists())
        self.assertEqual("2.0.0", plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["DieterReleaseVersion"])

    def test_failed_verification_or_late_process_guard_preserves_old_bundle(self):
        bundle = self.package()
        original = mac_bundle.inventory(bundle)
        (self.products / "DieterMac").write_text("new binary")
        for failure in ["verify", "guard"]:
            guards = 0
            def fail(argv, **kwargs):
                nonlocal guards
                if "assert_stopped()" in argv[-1]:
                    guards += 1
                if (failure == "verify" and argv[0].endswith("verify-bundle.sh")) or (failure == "guard" and guards == 2):
                    raise subprocess.CalledProcessError(1, argv)
                return self.record(argv, **kwargs)
            with self.assertRaises(subprocess.CalledProcessError):
                mac_bundle.package(self.root, self.products, "test-identity", run=fail)
            self.assertEqual(original, mac_bundle.inventory(bundle))
            self.assertEqual([], list(bundle.parent.glob(".Dieter.stage-*")))

    def test_framework_links_are_preserved_and_escaping_links_rejected(self):
        framework = self.products / "WebRTC.framework"
        (framework / "linked").symlink_to("resource with spaces")
        bundle = self.package()
        self.assertTrue((bundle / "Contents/Frameworks/WebRTC.framework/linked").is_symlink())
        (framework / "escape").symlink_to(self.root / "apps/mac/Resources/Info.plist")
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.package()

    def test_changed_implementation_identity_or_damaged_output_invalidates_manifest(self):
        bundle = self.package()
        (self.root / "fastlane/lib/dieter/native/mac_bundle.py").write_text("new packaging policy")
        self.calls.clear()
        self.package()
        self.assertTrue(any(call[0] == "codesign" for call in self.calls))
        self.calls.clear()
        mac_bundle.package(self.root, self.products, "another-identity", run=self.record)
        self.assertTrue(any(call[0] == "codesign" for call in self.calls))
        (bundle / "Contents/MacOS/DieterMac").write_text("damaged")
        self.package()
        self.assertEqual("content", (bundle / "Contents/MacOS/DieterMac").read_text())


if __name__ == "__main__":
    unittest.main()
