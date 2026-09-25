#!/usr/bin/env python3
"""Restore an exact recovery point onto an empty host; never overwrite a gateway."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import tempfile
import time
from common import ROOT, NAME, atomic, canonical, digest, pointer, read_json, require, run
from host import Host


def inspect_snapshot(snapshot):
    snapshot = Path(snapshot).resolve()
    metadata = read_json(snapshot / 'metadata.json')
    require(metadata.get('schema') == 1, 'unsupported recovery schema')
    datetime.datetime.fromisoformat(metadata['createdAt'])
    store = snapshot / 'gateway'
    require(store.is_dir() and not any(p.is_symlink() for p in store.rglob('*')), 'unsafe recovery store')
    require(digest(store / 'signing/daemon-ca.pem') == metadata['gatewayCAFingerprint'], 'recovery CA differs from metadata')
    for name in ('gateway-ed25519.pem', 'daemon-ca-ed25519.pem'):
        require((store / 'signing' / name).is_file(), 'recovery private identity missing')
    with sqlite3.connect('file:' + str(store / 'gateway.db') + '?mode=ro', uri=True) as db:
        require(db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', 'recovery database is corrupt')
        require(db.execute('PRAGMA user_version').fetchone()[0] == 1, 'incompatible recovery database')
    policy = read_json(snapshot / 'host-policy.json')
    settings = read_json(snapshot / 'release/public/settings.json')
    from render import settings as validate_settings
    validate_settings(settings)
    require(policy.get('gatewayIdentityHost', policy['gatewayHost']) == settings.get('gatewayIdentityHost', settings['gatewayHost']), 'snapshot gateway identity mismatch')
    require(policy.get('gatewayAliases', []) == settings.get('gatewayAliases', []), 'snapshot gateway aliases mismatch')
    for field in ('installRoot', 'configRoot', 'runtimeRoot', 'project', 'stateVolume', 'gatewayHost', 'allowedUserIDs',
                  'caddyData', 'caddyConfig', 'publicIPv4', 'turnIPv4', 'turnHost', 'legacyHosts'):
        require(policy[field] == settings[field], 'recovery settings differ from host policy')
    require(policy.get('controllerLink') == '/usr/local/lib/dieter-deploy', 'unsupported recovery controller path')
    require(Path(policy['stateRoot']).is_absolute(), 'invalid recovery state path')
    configuration = snapshot / 'configuration'
    for path in configuration.rglob('*'):
        if path.is_symlink():
            require(not Path(os.readlink(path)).is_absolute() and path.resolve().is_relative_to(configuration),
                    'recovery configuration symlink escapes its tree')
    compose = read_json(snapshot / 'release/public/compose.json')
    require(set(compose['services']) <= {'dieter-gateway', 'caddy', 'coturn', 'haproxy'}, 'unexpected recovery service')
    require('dieter-gateway' in compose['services'], 'recovery gateway service missing')
    images = {item['reference']: item['imageID'] for item in read_json(snapshot / 'images.json')}
    require((snapshot / 'images.tar').is_file(), 'runnable recovery image archive missing')
    for service in compose['services'].values():
        require(re.fullmatch(r'sha256:[a-f0-9]{64}', images.get(service['image'], '')), 'recovery image mapping missing')
    return snapshot, metadata, policy, settings, compose, images


def require_empty_destinations(policy, settings, volumes):
    paths = [policy[key] for key in ('installRoot', 'configRoot', 'stateRoot', 'runtimeRoot')]
    paths += [settings['caddyData'], settings['caddyConfig'], policy['controllerLink']]
    for value in paths:
        path = Path(value)
        require(not path.exists() and not path.is_symlink(), 'recovery destination already exists: ' + value)
    require(settings['stateVolume'] not in volumes, 'recovery volume already exists; refusing to overwrite identity')


def restored_compose(snapshot, settings, compose, images, release):
    """Resolve every bind to bytes present in the recovery set before mutation."""
    def source(value):
        path = Path(value)
        if not path.is_absolute():
            require(value == 'gateway-state', 'unknown recovery volume')
            return value
        for key, archived in (('configRoot', 'configuration'), ('caddyData', 'caddyData'), ('caddyConfig', 'caddyConfig')):
            base = Path(settings[key])
            if path.is_relative_to(base):
                require((snapshot / archived / path.relative_to(base)).exists(), 'recovery bind source is missing')
                return value
        if path == Path(settings['runtimeRoot']):
            return value
        base = Path(settings['installRoot']) / 'releases'
        if path.is_relative_to(base):
            parts = path.relative_to(base).parts
            require(len(parts) > 1 and (snapshot / 'release' / Path(*parts[1:])).is_file(), 'recovery release bind missing')
            return str(release / Path(*parts[1:]))
        raise ValueError('bind source is absent from the recovery archive: ' + value)
    result = json.loads(json.dumps(compose))
    for service in result['services'].values():
        service['image'] = images[service['image']]
        for environment in service.get('env_file', []):
            require((snapshot / 'configuration' / Path(environment['path']).relative_to(settings['configRoot'])).is_file(),
                    'recovery environment is missing')
        service['volumes'] = [':'.join([source(parts[0]), *parts[1:]])
                              for mount in service.get('volumes', []) for parts in [mount.split(':')]]
    return result


def recover(snapshot, operation, expected_ca, acknowledge_loss_after, confirm_host, activate=False):
    require(os.geteuid() == 0, 'recovery requires independent administrative root access')
    require(confirm_host == socket.gethostname(), 'recovery hostname confirmation differs from this host')
    require(NAME.fullmatch(operation), 'invalid recovery operation ID')
    snapshot, metadata, policy, settings, compose, images = inspect_snapshot(snapshot)
    require(expected_ca == metadata['gatewayCAFingerprint'], 'expected recovery CA differs')
    require(acknowledge_loss_after == metadata['createdAt'], 'acknowledge the exact snapshot time and its data-loss window')
    volumes = run(['docker', 'volume', 'ls', '--format', '{{.Name}}']).decode().splitlines()
    require_empty_destinations(policy, settings, volumes)
    require(not Path('/etc/dieter-deploy/host-policy.json').exists(), 'an installed host policy already exists')
    release = Path(policy['installRoot']) / 'releases' / ('recovered-' + operation)
    composed = restored_compose(snapshot, settings, compose, images, release)
    running = run(['docker', 'ps', '-q', '--filter', 'label=com.docker.compose.project=' + policy['project']]).strip()
    require(not running, 'a gateway project is already running on the recovery host')
    started = time.monotonic()
    # Cold validation cannot use the destination policy: that would create its
    # directories before the empty-host guard and would mix test and live state.
    with tempfile.TemporaryDirectory(prefix='dieter-recovery-check-') as temporary:
        root = Path(temporary)
        isolated = dict(policy, installRoot=str(root/'install'), configRoot=str(root/'config'),
                        stateRoot=str(root/'state'), runtimeRoot=str(root/'run'))
        atomic(root/'policy.json', canonical(isolated))
        Host(root/'policy.json').initialize()
        from restore_test import test_restore
        test_restore(snapshot, root/'policy.json')
    require_empty_destinations(policy, settings, run(['docker', 'volume', 'ls', '--format', '{{.Name}}']).decode().splitlines())
    record = Path(policy['stateRoot']) / 'recovery' / (operation + '.json')
    evidence = {'operation': operation, 'createdAt': metadata['createdAt'], 'gatewayCAFingerprint': expected_ca,
                'state': 'installing', 'snapshotDatabaseSHA256': digest(snapshot/'gateway/gateway.db'),
                'dataLossAfter': acknowledge_loss_after, 'independentRootRecovery': True}
    atomic(record, canonical(evidence))
    try:
        shutil.copytree(snapshot/'configuration', policy['configRoot'], symlinks=True)
        shutil.copytree(snapshot/'release', release, symlinks=True)
        for key in ('caddyData', 'caddyConfig'):
            shutil.copytree(snapshot/key, settings[key], symlinks=True)
        atomic(release/'public/compose.json', json.dumps(composed, indent=2), 0o644)
        for path in Path(policy['configRoot']).glob('releases/*/turnserver.conf'):
            os.chown(path, 0, 65533)
            path.chmod(0o640)
        turn_certificates = Path(policy['configRoot'])/'certificates/turn'
        for path in turn_certificates.rglob('*'):
            if not path.is_symlink():
                os.chown(path, 0, 65533)
                path.chmod(0o750 if path.is_dir() else 0o640)
        run(['docker', 'volume', 'create', '--label', 'dieter.recovery='+operation, settings['stateVolume']])
        volume = Path(json.loads(run(['docker','volume','inspect',settings['stateVolume']]))[0]['Mountpoint'])
        shutil.copytree(snapshot/'gateway', volume, dirs_exist_ok=True)
        for path in [volume, *volume.rglob('*')]:
            os.chown(path, 100, 101)
        volume.chmod(0o700)
        controller = Path(policy['installRoot'])/'recovery-controller'
        shutil.copytree(ROOT, controller, symlinks=False, ignore=shutil.ignore_patterns('__pycache__'))
        for path in (controller/'scripts').glob('*.py'):
            path.chmod(0o755)
        atomic('/etc/dieter-deploy/host-policy.json', canonical(policy))
        host = Host('/etc/dieter-deploy/host-policy.json')
        host.initialize()
        pointer(policy['controllerLink'], controller)
        pointer(Path(policy['installRoot'])/'current', release)
        for unit in (controller/'templates').glob('*'):
            if unit.suffix in ('.service', '.timer'):
                shutil.copyfile(unit, Path('/etc/systemd/system')/unit.name)
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'enable', 'dieter-deploy-reconcile.service'])
        evidence.update(state='installed', release=str(release))
        atomic(record, canonical(evidence))
        if activate:
            with host.lock():
                host.activate(release)
                manifest_path = release / 'gateway-manifest.json'
                host.wait_health(settings, read_json(manifest_path) if manifest_path.is_file() else None)
                require(digest(volume/'signing/daemon-ca.pem') == expected_ca, 'recovery changed gateway identity')
            evidence['state'] = 'active-awaiting-external-verification'
        evidence['durationSeconds'] = round(time.monotonic()-started, 2)
        atomic(record, canonical(evidence))
        return evidence
    except Exception as error:
        # Do not erase a partly restored identity. Administrative recovery must
        # inspect this record; a retry cannot silently overwrite partial state.
        evidence.update(state='failed', failureClass=type(error).__name__)
        atomic(record, canonical(evidence))
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', help='Protected directory restored from one exact encrypted repository snapshot.')
    parser.add_argument('--operation', help='Unique recovery ID; omission performs read-only inspection.')
    parser.add_argument('--expected-ca', help='Independently retained gateway CA SHA-256.')
    parser.add_argument('--acknowledge-loss-after', help='Exact createdAt from inspection; sessions/enrollments after it may be lost.')
    parser.add_argument('--confirm-host', help='Exact empty destination hostname; existing paths or volume are always rejected.')
    parser.add_argument('--activate', action='store_true', help='Start recovered services after offline validation; external acceptance is still required.')
    a = parser.parse_args()
    if a.operation:
        require(os.geteuid() == 0, 'recovery requires independent administrative root access')
        with open('/run/dieter-recovery.lock', 'a') as guard:
            os.fchmod(guard.fileno(), 0o600)
            fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print(json.dumps(recover(a.snapshot, a.operation, a.expected_ca, a.acknowledge_loss_after, a.confirm_host, a.activate)))
    else:
        require(not a.activate, 'activation requires a recovery operation')
        _, metadata, _, settings, _, _ = inspect_snapshot(a.snapshot)
        print(json.dumps({'createdAt': metadata['createdAt'], 'gatewayCAFingerprint': metadata['gatewayCAFingerprint'],
                          'gatewayHost': settings['gatewayHost'], 'stateVolume': settings['stateVolume'], 'schema': 1}))


if __name__ == '__main__':
    main()
