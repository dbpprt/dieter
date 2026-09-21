#!/usr/bin/env python3
"""Disposable Debian-only lifecycle fixture. Never run on a production host.

Use with debian-vm.yaml. The supplied distribution must retain its real CI
signatures. Fixture identity and certificates are generated locally; no operator
credentials enter the VM. The encrypted backup repository is local to this test
VM, so this fixture does not assert production off-host backup availability.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time

FIXTURE = Path('/opt/dieter-lifecycle-fixture')


def run(*argv, input=None, timeout=300):
    result = subprocess.run(list(map(str, argv)), input=input, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{argv[0]} failed: {result.stderr.decode()[-1500:]}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('setup', 'admit', 'accept', 'inspect', 'restore'))
    parser.add_argument('--distribution', default='/opt/dieter-distribution')
    parser.add_argument('--operation', default='candidate')
    a = parser.parse_args()
    if os.geteuid() != 0 or socket.gethostname() != 'lima-dieter-gateway-test':
        raise ValueError('this fixture requires the named disposable Lima VM')
    distribution = Path(a.distribution)
    bundle = distribution / 'bundle'
    sys.path.insert(0, str(bundle / 'scripts'))
    from common import atomic, canonical, pointer, read_json, digest
    from render import render
    from host import Host
    from install_tools import install
    from bundle import verify, ARCHIVE, MANIFEST, SIGNATURE
    policy_file = Path('/etc/dieter-deploy/host-policy.json')
    if a.command == 'setup':
        if FIXTURE.exists():
            raise ValueError('fixture already exists; inspect instead of overwriting')
        for name, destination in (('cosign', '/usr/local/bin/cosign'), ('oras', '/usr/local/bin/oras'),
                                  ('compose', '/usr/local/lib/docker/cli-plugins/docker-compose')):
            install(name, destination)
        manifest = verify(distribution)
        FIXTURE.mkdir(mode=0o700)
        config = read_json(bundle / 'profiles/example.settings.json')
        config.update(project='dieter-lifecycle', stateVolume='dieter-lifecycle-state', publicIPv4='198.18.0.2',
                      turnIPv4='198.18.0.2', installRoot=str(FIXTURE / 'install'), configRoot=str(FIXTURE / 'configuration'),
                      runtimeRoot='/run/dieter-lifecycle', caddyData=str(FIXTURE / 'caddy-data'), caddyConfig=str(FIXTURE / 'caddy-config'))
        private = {'githubClientID': 'fixture', 'githubClientSecret': 'fixture', 'authSecret': secrets.token_hex(32),
                   'turnSharedSecret': 'fixture-$"\\= café/' + secrets.token_hex(32)}
        policy = {key: config[key] for key in ('installRoot', 'configRoot', 'runtimeRoot', 'project', 'gatewayHost', 'allowedUserIDs')}
        policy.update(stateRoot=str(FIXTURE / 'state'), readinessTimeoutSeconds=600,
                      controllerLink='/usr/local/lib/dieter-deploy', backupCommand=[str(FIXTURE / 'backup.py')])
        atomic(policy_file, canonical(policy))
        host = Host(policy_file)
        host.initialize()
        atomic(host.etc / 'secrets.json', canonical(private))
        atomic(FIXTURE / 'settings.json', canonical(config))
        run('ip', 'address', 'add', '198.18.0.2/32', 'dev', 'lo')
        # Reapply only this fixture address after the actual VM restart test.
        atomic('/etc/systemd/system/dieter-fixture-address.service', '[Unit]\nBefore=dieter-deploy-reconcile.service\n[Service]\nType=oneshot\nExecStart=/usr/sbin/ip address replace 198.18.0.2/32 dev lo\nRemainAfterExit=yes\n[Install]\nWantedBy=multi-user.target\n', 0o644)
        with open('/etc/hosts', 'a') as hosts:
            hosts.write('\n198.18.0.2 '+config['gatewayHost']+' '+config['turnHost']+'\n')
        cert = FIXTURE / 'cert-source'
        cert.mkdir()
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-keyout', cert / 'ca.key',
            '-out', cert / 'ca.crt', '-subj', '/CN=Dieter disposable lifecycle CA',
            '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        run('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', cert / 'key.pem',
            '-out', cert / 'server.csr', '-subj', '/CN='+config['gatewayHost'])
        atomic(cert / 'extensions', 'subjectAltName=DNS:'+config['gatewayHost']+',DNS:'+config['turnHost']+'\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature,keyEncipherment\nbasicConstraints=critical,CA:FALSE\n')
        run('openssl', 'x509', '-req', '-in', cert / 'server.csr', '-CA', cert / 'ca.crt', '-CAkey', cert / 'ca.key',
            '-set_serial', '1', '-days', '2', '-extfile', cert / 'extensions', '-out', cert / 'fullchain.pem')
        shutil.copyfile(cert / 'ca.crt', '/usr/local/share/ca-certificates/dieter-lifecycle.crt')
        run('update-ca-certificates')
        for kind in ('gateway', 'turn'):
            generation = host.etc / 'certificates' / kind / 'fixture'
            generation.mkdir(parents=True, mode=0o755)
            atomic(generation / 'fullchain.pem', (cert / 'fullchain.pem').read_bytes(), 0o644)
            atomic(generation / 'privkey.pem', (cert / 'key.pem').read_bytes(), 0o640)
            os.chown(generation / 'privkey.pem', 0, 65533)
            pointer(generation.parent / 'current', generation.name)
        # Certificate ancestors must be traversable inside the read-only mount.
        for path in (host.etc / 'certificates').rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
        (host.etc / 'certificates').chmod(0o755)
        (host.etc / 'acme-webroot').mkdir()
        baseline = host.install / 'releases/baseline'
        shutil.copytree(bundle, baseline)
        rendered = render(config, private, manifest['image'], 'baseline', FIXTURE / 'rendered')
        shutil.copytree(rendered / 'public', baseline / 'public')
        shutil.copytree(rendered / 'private', host.etc / 'releases/baseline')
        turn = host.etc / 'releases/baseline/turnserver.conf'
        os.chown(turn, 0, 65533)
        turn.chmod(0o640)
        run('docker', 'volume', 'create', config['stateVolume'])
        volume = Path(json.loads(run('docker', 'volume', 'inspect', config['stateVolume']))[0]['Mountpoint'])
        os.chown(volume, 100, 101)
        volume.chmod(0o700)
        pointer(host.install / 'current', baseline)
        pointer('/usr/local/lib/dieter-deploy', baseline)
        deps = manifest['dependencies']
        host.compose(baseline, 'pull')
        host.activate(baseline)
        for attempt in range(60):
            try:
                host.health(config, manifest['sourceRevision'])
                break
            except Exception:
                time.sleep(1)
        else:
            raise ValueError('fixture edge failed to start')
        atomic(FIXTURE / 'initial-ca.sha256', digest(volume / 'signing/daemon-ca.pem'))
        repository = FIXTURE / 'repository'
        repository.mkdir()
        atomic(FIXTURE / 'backup-password', secrets.token_hex(32))
        backup = '''#!/usr/bin/env python3
import json,subprocess,sys
from pathlib import Path
r=Path('/opt/dieter-lifecycle-fixture')
image=IMAGE
base=['docker','run','--rm','--network','none','--memory','192m','--cpus','0.4','-e','RESTIC_PASSWORD_FILE=/password','-v',str(r/'backup-password')+':/password:ro','-v',str(r/'repository')+':/repository','-v',sys.argv[1]+':/snapshot:ro',image,'--no-cache','--repo','/repository']
p=subprocess.run(base+['backup','/snapshot','--json'],capture_output=True,timeout=600)
if p.returncode: raise RuntimeError('encrypted fixture backup failed')
print(json.dumps({'encryptedFixtureBackup':True}))
'''.replace('IMAGE', repr(deps['restic']))
        atomic(FIXTURE / 'backup.py', backup, 0o755)
        run('docker', 'run', '--rm', '--network', 'none', '-e', 'RESTIC_PASSWORD_FILE=/password',
            '-v', str(FIXTURE / 'backup-password')+':/password:ro', '-v', str(repository)+':/repository',
            deps['restic'], '--repo', '/repository', 'init')
        for unit in (bundle / 'templates').glob('*'):
            shutil.copyfile(unit, Path('/etc/systemd/system') / unit.name)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', 'dieter-deploy-reconcile.service', 'dieter-fixture-address.service')
        print(json.dumps({'fixtureReady': True, 'cpus': os.cpu_count(), 'sourceRevision': manifest['sourceRevision']}))
        return
    host = Host(policy_file)
    config = read_json(FIXTURE / 'settings.json')
    if a.command == 'admit':
        incoming = FIXTURE / 'incoming'
        incoming.mkdir(exist_ok=True)
        for name in (ARCHIVE, MANIFEST, SIGNATURE):
            shutil.copyfile(distribution / name, incoming / name)
        shutil.copyfile(FIXTURE / 'settings.json', incoming / 'settings.json')
        print(json.dumps(host.admit(a.operation, incoming)))
    elif a.command == 'accept':
        status = host.status(a.operation)
        if status['state'] != 'checking':
            raise ValueError('fixture is not checking')
        probe = bundle / 'bin/gateway-turn-probe-linux-arm64'
        run(probe, input=canonical({'address': '198.18.0.2:443', 'serverName': config['gatewayHost'], 'transport': 'https'}))
        private = read_json(host.etc / 'secrets.json')
        for transport in ('udp', 'tcp', 'tls'):
            username = str(int(time.time())+180)+':dieter:1:lifecycle'
            password = base64.b64encode(hmac.new(private['turnSharedSecret'].encode(), username.encode(), hashlib.sha1).digest()).decode()
            run(probe, input=canonical({'address': '198.18.0.2:'+('443' if transport == 'tls' else '3478'),
                'serverName': config['turnHost'], 'transport': transport, 'username': username, 'password': password, 'expectedRelayIP': '198.18.0.2'}))
        # This is a trusted fixture controller's acceptance message. Production
        # readiness separately requires existing enrolled gateway/daemon clients.
        report = dict(requestSHA256=status['requestSHA256'], sourceRevision=status['sourceRevision'],
                      gatewayAuthenticated=True, daemonAuthenticated=True, unauthenticatedRejected=True,
                      turnPayloadTransports=['udp', 'tcp', 'tls'], fixtureOnly=True)
        atomic(FIXTURE / 'readiness.json', canonical(report))
        print(json.dumps(host.accept(a.operation, FIXTURE / 'readiness.json')))
    elif a.command == 'restore':
        from restore_test import test_restore
        destination = FIXTURE / 'restored'
        if destination.exists():
            raise ValueError('restore destination already exists')
        destination.mkdir()
        deps = read_json(bundle / 'dependencies.lock.json')
        run('docker', 'run', '--rm', '--network', 'none', '-e', 'RESTIC_PASSWORD_FILE=/password',
            '-v', str(FIXTURE / 'backup-password')+':/password:ro', '-v', str(FIXTURE / 'repository')+':/repository:ro',
            '-v', str(destination)+':/restore', deps['restic'], '--no-cache', '--no-lock', '--repo', '/repository',
            'restore', 'latest', '--target', '/restore', '--verify')
        print(json.dumps(test_restore(destination / 'snapshot', policy_file)))
    else:
        state = host.status(a.operation)
        state['identityPreserved'] = digest(host.volume(config) / 'signing/daemon-ca.pem') == (FIXTURE / 'initial-ca.sha256').read_text()
        state['currentRelease'] = (host.install / 'current').resolve().name
        print(json.dumps(state))


if __name__ == '__main__':
    main()
