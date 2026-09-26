import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import bundle
import upgrade_controller
from host import Host


class ControllerUpgradeTests(unittest.TestCase):
    def test_verified_upgrade_preserves_services_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            distribution = root / 'distribution'
            manifest = bundle.pack(distribution, 'a'*40, '0.4.309',
                                   'ghcr.io/dbpprt/dieter-gateway@sha256:' + 'b'*64, 'fixture')
            (distribution / bundle.SIGNATURE).write_text('fixture signature')
            old = root / 'old-controller'
            old.mkdir()
            link = root / 'controller'
            link.symlink_to(old)
            policy = root / 'policy.json'
            policy.write_text(json.dumps({key: str(root / key) for key in
                                          ('installRoot', 'configRoot', 'stateRoot', 'runtimeRoot')} |
                                         {'controllerLink': str(link)}))
            host = Host(policy)
            host.initialize()
            (host.install / 'current').symlink_to(old)
            with patch.object(upgrade_controller, 'verify', return_value=manifest) as verified:
                receipt = upgrade_controller.upgrade(distribution, policy)
                self.assertEqual(upgrade_controller.upgrade(distribution, policy), receipt)
                self.assertEqual(verified.call_count, 2)
            self.assertEqual((host.install / 'current').resolve(), old)
            self.assertEqual(receipt['previousController'], str(old))
            self.assertFalse(receipt['serviceActivation'])
            self.assertEqual(link.resolve(), Path(receipt['controller']))
            self.assertTrue((link / 'scripts/host.py').is_file())

    def test_untrusted_bundle_cannot_move_controller(self):
        with patch.object(upgrade_controller, 'verify', side_effect=ValueError('signature')), \
             patch.object(upgrade_controller, 'Host') as host:
            with self.assertRaisesRegex(ValueError, 'signature'):
                upgrade_controller.upgrade('/fixture', '/policy')
            host.assert_not_called()
