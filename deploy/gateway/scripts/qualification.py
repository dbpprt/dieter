"""Bind legacy route retirement to measured TLS qualification and host time."""
import datetime
import hashlib
import re
from common import atomic, canonical, read_json, require, keys
from bundle import MANIFEST

CHECKS = ('macAPI', 'macScreens', 'androidAPI', 'androidScreens', 'gatewayIssuedTURN',
          'certificateRenewal', 'invalidCertificatesRejected', 'legacyAuthentication',
          'accountIsolation', 'steadyLoad', 'reconnectLoad')
OBSERVATION_CHECKS = ('homeOfficeClients', 'normalPeerSync', 'gatewayHealthy', 'turnHealthy')


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc)


def record(host, operation, report):
    status = host.status(operation)
    current = host.install / 'current'
    require(status['state'] == 'committed' and current.resolve().name == operation, 'qualification requires the current accepted operation')
    selection = read_json(current / 'public/settings.json')
    require(selection['tls'] == 'managed' and selection['legacyHosts'], 'qualification requires the transitional TLS topology')
    keys(report, ('requestSHA256', 'sourceRevision', 'checks', 'steadySeconds', 'reconnectSeconds', 'evidenceSHA256'), 'qualification report')
    require(report['requestSHA256'] == status['requestSHA256'] and report['sourceRevision'] == status['sourceRevision'],
            'qualification evidence belongs to different deployment inputs')
    keys(report['checks'], CHECKS, 'qualification checks')
    require(all(value is True for value in report['checks'].values()), 'every TLS/native/capacity check must pass')
    require(type(report['steadySeconds']) is int and report['steadySeconds'] >= 1800 and
            type(report['reconnectSeconds']) is int and report['reconnectSeconds'] >= 300, 'qualification workload is incomplete')
    require(re.fullmatch(r'[a-f0-9]{64}', report['evidenceSHA256']), 'qualification evidence requires a retained report hash')
    path = host.state / 'qualification.json'
    if path.is_file():
        existing = read_json(path)
        if existing['operation'] == operation and existing['report'] == report:
            return existing
    received = utcnow()
    result = {'operation': operation, 'report': report, 'receivedAt': received.isoformat(),
              'retirementEligibleAt': (received + datetime.timedelta(hours=24)).isoformat()}
    atomic(path, canonical(result))
    return result


def record_observation(host, operation, report):
    qualification = read_json(host.state / 'qualification.json')
    require(qualification['operation'] == operation and (host.install/'current').resolve().name == operation,
            'observation belongs to a different deployment')
    require(utcnow() >= datetime.datetime.fromisoformat(qualification['retirementEligibleAt']),
            'the 24-hour observation interval has not completed')
    keys(report, ('observedSince', 'checks', 'evidenceSHA256'), 'observation report')
    require(report['observedSince'] == qualification['receivedAt'], 'observation must cover the full qualification interval')
    keys(report['checks'], OBSERVATION_CHECKS, 'observation checks')
    require(all(value is True for value in report['checks'].values()), 'normal-use observation is incomplete')
    require(re.fullmatch(r'[a-f0-9]{64}', report['evidenceSHA256']), 'observation requires a retained evidence report hash')
    result = {'operation': operation, 'report': report, 'receivedAt': utcnow().isoformat(),
              'qualificationSHA256': hashlib.sha256(canonical(qualification)).hexdigest()}
    atomic(host.state/'observation.json', canonical(result))
    return result


def require_retirement_ready(host, incoming):
    current = host.install / 'current'
    selection = read_json(current / 'public/settings.json')
    if not selection['legacyHosts']:
        return  # The accepted topology has already passed its removal gate.
    path = host.state / 'qualification.json'
    require(path.is_file(), 'legacy retirement requires recorded TLS/native/capacity qualification')
    evidence = read_json(path)
    status = host.status(current.resolve().name)
    require(selection['tls'] == 'managed' and status['state'] == 'committed', 'transitional TLS has not been accepted')
    require(evidence['operation'] == status['id'] and evidence['report']['requestSHA256'] == status['requestSHA256'],
            'qualification belongs to a different accepted deployment')
    require(all(evidence['report']['checks'].get(check) is True for check in CHECKS), 'qualification checks are incomplete')
    require(read_json(incoming / MANIFEST)['sourceRevision'] == status['sourceRevision'],
            'retirement must retain the qualified gateway release')
    require(utcnow() >= datetime.datetime.fromisoformat(evidence['retirementEligibleAt']), 'the 24-hour observation interval has not completed')
    observation_path = host.state/'observation.json'
    require(observation_path.is_file(), 'normal-use observation evidence has not been recorded')
    observation = read_json(observation_path)
    require(observation['qualificationSHA256'] == hashlib.sha256(canonical(evidence)).hexdigest(),
            'observation belongs to different qualification evidence')
