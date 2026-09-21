#!/usr/bin/env python3
"""Measure allocation lifecycle on the named disposable VM, not native capacity."""
import argparse
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import subprocess
import time


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE, timeout=20)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--probe', required=True, help='Linux ARM64 gateway-turn-probe binary; its SHA-256 is recorded.')
    p.add_argument('--output', required=True, help='New protected evidence directory.')
    p.add_argument('--steady-seconds', type=int, default=1800)
    p.add_argument('--reconnect-seconds', type=int, default=300)
    a = p.parse_args()
    assert os.geteuid() == 0 and socket.gethostname() == 'lima-dieter-gateway-test', 'Only the disposable VM is supported'
    assert 1 <= a.steady_seconds <= 1800 and 1 <= a.reconnect_seconds <= 300
    root = Path(a.output)
    assert not root.exists()
    root.mkdir(mode=0o700, parents=True)
    fixture = Path('/opt/dieter-lifecycle-fixture')
    settings = json.loads((fixture/'install/current/public/settings.json').read_text())
    assert settings['project'] == 'dieter-lifecycle' and settings['turn']['userQuota'] == 64 and settings['turn']['totalQuota'] == 256
    assert settings['turn']['bpsCapacity'] >= settings['turn']['maxBps'] * settings['turn']['totalQuota']
    secret = json.loads((fixture/'configuration/secrets.json').read_text())['turnSharedSecret']
    info = json.loads(command('docker', 'inspect', 'dieter-lifecycle-coturn-1'))[0]
    container, pid = info['Id'], info['State']['Pid']
    assert pid > 0 and info['Config']['Labels']['com.docker.compose.project'] == 'dieter-lifecycle'
    active = []
    report = {'kind': 'allocation-lifecycle-soak', 'nativeQualification': False,
              'probesCoLocated': True, 'throughputQualification': False,
              'turnBounds': settings['turn'],
              'probeSHA256': hashlib.sha256(Path(a.probe).read_bytes()).hexdigest(),
              'steadySeconds': a.steady_seconds, 'reconnectSeconds': a.reconnect_seconds,
              'pairs': 32, 'expectedPeakAllocations': 64, 'payloadBytes': 1024,
              'payloadCadenceSeconds': 1, 'samples': [], 'runs': [], 'passed': False}

    def sample(phase):
        fds = list(Path(f'/proc/{pid}/fd').iterdir())
        inodes = set()
        for fd in fds:
            try:
                target = os.readlink(fd)
                if target.startswith('socket:['): inodes.add(target[8:-1])
            except FileNotFoundError:
                pass
        allocations = sum(1 for row in Path('/proc/net/udp').read_text().splitlines()[1:]
                          if row.split()[9] in inodes and 49160 <= int(row.split()[1].split(':')[1], 16) <= 50183)
        memory = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
        available = int(memory['MemAvailable'].split()[0]) * 1024
        stat = json.loads(command('docker', 'inspect', container))[0]
        assert stat['State']['Running'] and not stat['State']['OOMKilled']
        assert stat['State']['Pid'] == pid, 'coturn restarted during measurement'
        assert available > 96*1024*1024, 'fixture host memory reserve exhausted'
        measured = json.loads(command('docker', 'stats', '--no-stream', '--format', '{{json .}}', container))
        row = {'phase': phase, 'at': time.time(), 'allocations': allocations, 'fds': len(fds),
               'hostAvailableBytes': available, 'cpu': measured['CPUPerc'], 'memory': measured['MemUsage']}
        report['samples'].append(row)
        return row

    def start(index, duration, phase):
        transport = ('udp', 'tcp', 'tls')[index % 3]
        username = f'{int(time.time())+3600}:dieter:fixture:concentrated-target'
        password = base64.b64encode(hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()).decode()
        request = {'address': '198.18.0.2:' + ('443' if transport == 'tls' else '3478'),
                   'serverName': settings['turnHost'], 'transport': transport, 'username': username,
                   'password': password, 'expectedRelayIP': '198.18.0.2', 'holdSeconds': duration,
                   'caFile': str(fixture/'cert-source/ca.crt')}
        output = root / f'{phase}-{index}.json'
        errors = root / f'{phase}-{index}.error'
        with output.open('wb') as out, errors.open('wb') as err:
            process = subprocess.Popen([a.probe], stdin=subprocess.PIPE, stdout=out, stderr=err)
        process.stdin.write(json.dumps(request).encode())
        process.stdin.close()
        active.append((process, transport, output))

    def finish():
        for process, transport, output in active:
            code = process.wait(timeout=50)
            assert code == 0, 'TURN probe failed; inspect protected transport error'
            result = json.loads(output.read_text())
            assert result['payloadBidirectional'] and result['relayAddressVerified']
            report['runs'].append({'transport': transport, 'result': result})
        active.clear()

    try:
        assert sample('baseline')['allocations'] == 0, 'fixture already has active allocations'
        for index in range(32):
            start(index, a.steady_seconds, 'steady')
            time.sleep(0.05)
        began = time.monotonic()
        next_status = began
        while time.monotonic() - began < a.steady_seconds:
            assert all(process.poll() in (None, 0) for process, _, _ in active), 'allocation failed'
            row = sample('steady')
            if time.monotonic() >= next_status:
                print(json.dumps(row), flush=True)
                next_status = time.monotonic() + 60
            time.sleep(min(10, max(0, a.steady_seconds - (time.monotonic() - began))))
        finish()
        assert max(row['allocations'] for row in report['samples']) == 64, 'concentrated allocation target was not reached'
        deadline = time.monotonic()+30
        while sample('release')['allocations']:
            assert time.monotonic() < deadline, 'allocations did not release within 30 seconds'
            time.sleep(1)
        began = time.monotonic()
        burst = 0
        while time.monotonic()-began < a.reconnect_seconds:
            for index in range(12): start(index, 1, 'reconnect-'+str(burst))
            finish()
            row = sample('reconnect')
            print(json.dumps(row), flush=True)
            burst += 1
            time.sleep(min(15, max(0, a.reconnect_seconds-(time.monotonic()-began))))
        deadline = time.monotonic()+30
        while sample('final-release')['allocations']:
            assert time.monotonic() < deadline, 'reconnect allocations did not release'
            time.sleep(1)
        report.update(passed=True, reconnectBursts=burst)
    finally:
        unfinished = [process for process, _, _ in active if process.poll() is None]
        for process in unfinished: process.terminate()
        for process in unfinished: process.wait(timeout=10)
        if unfinished:
            # Only the named disposable fixture has been admitted above. Failed
            # UDP probes may leave allocations behind when terminated early.
            command('docker', 'restart', '--time', '10', container)
            report['fixtureTURNRestartedAfterFailure'] = True
        (root/'report.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({'passed': report['passed'], 'nativeQualification': False, 'evidence': str(root)}), flush=True)


if __name__ == '__main__':
    main()
