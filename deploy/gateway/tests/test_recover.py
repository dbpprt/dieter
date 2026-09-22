import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from recover import require_empty_destinations, restored_compose


class RecoveryGuardsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.policy = {key: str(self.root/key) for key in ('installRoot', 'configRoot', 'stateRoot', 'runtimeRoot', 'controllerLink')}
        self.settings = dict(self.policy, stateVolume='fixture-state', caddyData=str(self.root/'data'), caddyConfig=str(self.root/'config'))

    def test_existing_state_is_rejected_without_mutation(self):
        path = Path(self.policy['stateRoot'])
        path.mkdir()
        sentinel = path/'operator-state'
        sentinel.write_text('preserve')
        with self.assertRaisesRegex(ValueError, 'destination already exists'):
            require_empty_destinations(self.policy, self.settings, [])
        self.assertEqual(sentinel.read_text(), 'preserve')

    def test_existing_named_volume_cannot_be_replaced(self):
        with self.assertRaisesRegex(ValueError, 'volume already exists'):
            require_empty_destinations(self.policy, self.settings, ['fixture-state'])

    def test_recovery_uses_archived_image_id_and_preserves_environment_location(self):
        snapshot = self.root/'snapshot'
        (snapshot/'release/public').mkdir(parents=True)
        (snapshot/'release/public/Caddyfile').write_text('fixture')
        (snapshot/'configuration/releases/old').mkdir(parents=True)
        (snapshot/'configuration/releases/old/gateway.env').write_text('fixture=value\n')
        image = 'registry/gateway@sha256:'+'a'*64
        environment = str(Path(self.policy['configRoot'])/'releases/old/gateway.env')
        compose = {'services': {'dieter-gateway': {'image': image,
                    'env_file': [{'path': environment, 'format': 'raw'}],
                    'volumes': ['gateway-state:/var/lib/dieter-gateway', self.policy['installRoot']+'/releases/old/public/Caddyfile:/etc/caddy/Caddyfile:ro']}}}
        before = json.dumps(compose)
        release = self.root/'new-release'
        result = restored_compose(snapshot, self.settings, compose, {image: 'sha256:'+'b'*64}, release)
        service = result['services']['dieter-gateway']
        self.assertEqual(service['image'], 'sha256:'+'b'*64)
        self.assertEqual(service['env_file'][0]['path'], environment)
        self.assertEqual(service['volumes'][1], str(release/'public/Caddyfile')+':/etc/caddy/Caddyfile:ro')
        self.assertEqual(json.dumps(compose), before)
        compose['services']['dieter-gateway']['volumes'].append('/outside/recovery:/configuration:ro')
        with self.assertRaisesRegex(ValueError, 'absent from the recovery archive'):
            restored_compose(snapshot, self.settings, compose, {image: 'sha256:'+'b'*64}, release)


if __name__ == '__main__':
    unittest.main()
