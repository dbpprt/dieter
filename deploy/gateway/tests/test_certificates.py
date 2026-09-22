import sys
from pathlib import Path
import unittest
from unittest.mock import call, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from certificates import activate


class CertificateAliasTests(unittest.TestCase):
    def test_missing_alias_coverage_rejected_before_certificate_publication(self):
        selection = {"gatewayHost": "gateway.new.example", "gatewayAliases": ["gateway.old.example"]}
        with patch("certificates.validate", side_effect=[None, ValueError("missing alias")]) as validate:
            with patch("certificates.digest") as digest:
                with self.assertRaisesRegex(ValueError, "missing alias"):
                    activate(None, selection, "gateway", "chain", "key")
                digest.assert_not_called()
        self.assertEqual(validate.call_args_list, [call("chain", "key", "gateway.new.example"),
                                                   call("chain", "key", "gateway.old.example")])
