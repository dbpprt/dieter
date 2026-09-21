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
                bundle.pack(directory, "b" * 40, "v1.0.0", image, "2026-09-21T00:00:00Z")
            self.assertEqual(digest(dirs[0] / bundle.ARCHIVE), digest(dirs[1] / bundle.ARCHIVE))
            with patch.object(bundle, "verify_signature"):
                bundle.verify(dirs[0], "b" * 40, image, image_signature=False)
                with (dirs[0] / bundle.ARCHIVE).open("ab") as f:
                    f.write(b"tampered")
                with self.assertRaisesRegex(ValueError, "checksum"):
                    bundle.verify(dirs[0], image_signature=False)

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
