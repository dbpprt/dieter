import datetime
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from host import Host
from common import atomic, canonical, pointer
from bundle import MANIFEST
from qualification import CHECKS, OBSERVATION_CHECKS, record, record_observation, require_retirement_ready


class QualificationTests(unittest.TestCase):
    def test_retirement_requires_complete_current_evidence_and_full_observation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = {key: str(root/key) for key in ('installRoot', 'configRoot', 'stateRoot', 'runtimeRoot')}
            atomic(root/'policy.json', canonical(policy))
            host = Host(root/'policy.json'); host.initialize()
            release = host.install/'releases/qualified'
            atomic(release/'public/settings.json', canonical({'tls': 'managed', 'legacyHosts': ['old.example.com']}))
            pointer(host.install/'current', release)
            host.transition('qualified', 'committed', requestSHA256='a'*64, sourceRevision='b'*40)
            incoming = root/'incoming'
            atomic(incoming/MANIFEST, canonical({'sourceRevision': 'b'*40}))
            with self.assertRaisesRegex(ValueError, 'requires recorded'):
                require_retirement_ready(host, incoming)
            report = {'requestSHA256': 'a'*64, 'sourceRevision': 'b'*40,
                      'checks': {check: True for check in CHECKS}, 'steadySeconds': 1800,
                      'reconnectSeconds': 300, 'evidenceSHA256': 'c'*64}
            for invalid in (dict(report, steadySeconds=1799), dict(report, sourceRevision='d'*40),
                            dict(report, checks=dict(report['checks'], macScreens=False))):
                with self.assertRaises(ValueError): record(host, 'qualified', invalid)
            now = datetime.datetime(2026, 9, 21, tzinfo=datetime.timezone.utc)
            with patch('qualification.utcnow', return_value=now):
                first = record(host, 'qualified', report)
                self.assertEqual(record(host, 'qualified', report), first)
                with self.assertRaisesRegex(ValueError, '24-hour'):
                    require_retirement_ready(host, incoming)
            with patch('qualification.utcnow', return_value=now+datetime.timedelta(hours=24)):
                with self.assertRaisesRegex(ValueError, 'observation evidence'):
                    require_retirement_ready(host, incoming)
                record_observation(host, 'qualified', {'observedSince': first['receivedAt'],
                    'checks': {check: True for check in OBSERVATION_CHECKS}, 'evidenceSHA256': 'e'*64})
                require_retirement_ready(host, incoming)
                atomic(incoming/MANIFEST, canonical({'sourceRevision': 'd'*40}))
                with self.assertRaisesRegex(ValueError, 'retain the qualified'):
                    require_retirement_ready(host, incoming)


if __name__ == '__main__':
    unittest.main()
