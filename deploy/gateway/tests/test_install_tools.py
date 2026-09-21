import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import install_tools
import bundle


class ToolIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = b"verified executable bytes"
        self.entry = {"url": "https://github.com/example/tool/releases/download/v1/tool", "sha256": hashlib.sha256(self.binary).hexdigest(), "archiveMember": None}
        (self.root / "tools.lock.json").write_text(json.dumps({"tool": {"linux/arm64": self.entry}}))
        for target, value in (("install_tools.ROOT", self.root), ("install_tools.platform.system", lambda: "Linux"),
                              ("install_tools.platform.machine", lambda: "aarch64")):
            p = patch(target, value)
            p.start()
            self.addCleanup(p.stop)
        self.destination = self.root / "bin/tool"

    def test_verified_cache_avoids_network_but_detects_tampering(self):
        with patch("install_tools.urllib.request.urlopen", return_value=io.BytesIO(self.binary)):
            install_tools.install("tool", self.destination)
        with patch("install_tools.urllib.request.urlopen", side_effect=AssertionError("cache should be local")):
            install_tools.install("tool", self.destination)
        self.destination.write_bytes(b"tampered")
        with patch("install_tools.urllib.request.urlopen", return_value=io.BytesIO(self.binary)) as download:
            install_tools.install("tool", self.destination)
            download.assert_called_once()
        self.assertEqual(self.destination.read_bytes(), self.binary)

    def test_bad_download_never_replaces_a_binary(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b"previous verified version")
        with patch("install_tools.urllib.request.urlopen", return_value=io.BytesIO(b"wrong artifact")):
            with self.assertRaisesRegex(ValueError, "checksum"):
                install_tools.install("tool", self.destination)
        self.assertEqual(self.destination.read_bytes(), b"previous verified version")

    def test_transient_download_retries_are_bounded(self):
        with patch("install_tools.time.sleep"), patch("install_tools.urllib.request.urlopen",
                side_effect=urllib.error.URLError("temporary failure")) as download:
            with self.assertRaises(urllib.error.URLError):
                install_tools.install("tool", self.destination)
        self.assertEqual(download.call_count, 4)
        self.assertFalse(self.destination.exists())

    def test_signing_retry_still_fails_closed(self):
        with patch("bundle.time.sleep"), patch("bundle.run", side_effect=ValueError("signing failed")) as signer:
            with self.assertRaises(ValueError):
                bundle.publish_retry(["cosign", "sign", "pinned-image"])
        self.assertEqual(signer.call_count, 4)


if __name__ == "__main__":
    unittest.main()
