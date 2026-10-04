"""E2E container visibility cannot escape into a production app or archive."""

from pathlib import Path
import plistlib
import tempfile
import unittest

from fastlane.lib.dieter.native.ios_e2e_metadata import configure


class E2EMetadataTest(unittest.TestCase):
    def test_only_debug_e2e_identity_can_expose_owned_files(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "Info.plist"
            for configuration, bundle in (("Release", "com.example.e2e"),
                                          ("Debug", "com.example.dieter")):
                original = plistlib.dumps(dict(CFBundleIdentifier=bundle, CFBundleDisplayName="Dieter"))
                path.write_bytes(original)
                configure(path, configuration, bundle)
                self.assertEqual(path.read_bytes(), original)
            path.write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.example.e2e", DieterReleaseVersion="0.4.413")))
            path.chmod(0o644)
            configure(path, "Debug", "com.example.e2e")
            info = plistlib.loads(path.read_bytes())
            self.assertIs(info["UIFileSharingEnabled"], True)
            self.assertIs(info["LSSupportsOpeningDocumentsInPlace"], True)
            self.assertEqual(info["DieterReleaseVersion"], "0.4.413")
            self.assertEqual(info["CFBundleDisplayName"], "Dieter E2E")
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)

    def test_mismatched_actual_bundle_is_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "Info.plist"
            original = plistlib.dumps(dict(CFBundleIdentifier="com.example.operator"))
            path.write_bytes(original)
            with self.assertRaises(ValueError):
                configure(path, "Debug", "com.example.e2e")
            self.assertEqual(path.read_bytes(), original)
