import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import bundle
from common import digest


class BundleTests(unittest.TestCase):
    def test_reproducible_pack_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            dirs = [Path(temp) / "one", Path(temp) / "two"]
            image = "ghcr.io/dbpprt/dieter-gateway@sha256:" + "a" * 64
            for directory in dirs:
                manifest = bundle.pack(directory, "b" * 40, "v1.0.0", image, "2026-09-21T00:00:00Z")
                self.assertEqual(manifest['releaseVersion'], "1.0.0")
                self.assertEqual(manifest['compatibilityPolicy'], {
                    'minimumClientVersion': '0.4.309-dev.0',
                    'minimumDaemonVersion': '0.4.309-dev.0'})
            self.assertEqual(digest(dirs[0] / bundle.ARCHIVE), digest(dirs[1] / bundle.ARCHIVE))
            with patch.object(bundle, "verify_signature"):
                bundle.verify(dirs[0], "b" * 40, image, image_signature=False)
                with (dirs[0] / bundle.ARCHIVE).open("ab") as f:
                    f.write(b"tampered")
                with self.assertRaisesRegex(ValueError, "checksum"):
                    bundle.verify(dirs[0], image_signature=False)

    def test_deployment_interface_carries_resolved_compatibility_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = bundle.pack(temp, "b" * 40, "0.4.309", "ghcr.io/dbpprt/dieter-gateway@sha256:" + "a" * 64, "fixture")
            older = {'minimumClientVersion': '0.4.300', 'minimumDaemonVersion': '0.4.301'}
            bundle.validate_manifest(dict(manifest, compatibilityPolicy=older))
            for invalid in ({}, {'minimumClientVersion': 'not-semver', 'minimumDaemonVersion': '0.4.1'},
                            {'minimumClientVersion': '0.4.310', 'minimumDaemonVersion': '0.4.1'}):
                with self.assertRaises(ValueError):
                    bundle.validate_manifest(dict(manifest, compatibilityPolicy=invalid))
            for field in ('manifestVersion', 'bundleInterfaceVersion', 'gatewayStoreSchema'):
                with self.assertRaisesRegex(ValueError, "incompatible"):
                    bundle.validate_manifest(dict(manifest, **{field: 2}))

    def test_untrusted_signature_never_reaches_extraction(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(bundle, "run", side_effect=ValueError("untrusted")):
            with self.assertRaisesRegex(ValueError, "signature"):
                bundle.verify(temp)

    def test_archive_rejects_traversal_links_and_duplicates(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("link", tarfile.LNKTYPE)):
            with self.subTest(name=name, kind=kind), tempfile.TemporaryDirectory() as temp:
                archive = Path(temp) / "test.tgz"
                with tarfile.open(archive, "w:gz") as tar:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/etc/passwd"
                    tar.addfile(member, io.BytesIO())
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    bundle.extract(archive, Path(temp) / "out")


if __name__ == "__main__":
    unittest.main()
