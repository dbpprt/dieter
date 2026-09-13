#!/usr/bin/env python3
"""Exercise the native iOS app against disposable enrolled remote nodes.

Only the simulator and gateway created by this run are stopped. Operator apps,
daemons, credentials, and existing simulators are never modified.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'apps/ios/.build'


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def retain_gateway_log(private_log, output_log):
    text = private_log.read_text(errors='replace')
    for line in text.splitlines():
        if line.startswith('DIETER_ISOLATED_TOKEN='):
            token = line.split('=', 1)[1]
            if token:
                text = text.replace(token, '<redacted>')
    output_log.write_text(text)
    os.chmod(output_log, 0o600)
    private_log.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', default='iPhone 17 Pro')
    parser.add_argument('--https-gateway', default=os.environ.get('DIETER_IOS_SMOKE_HTTPS_GATEWAY'), help='Optional HTTPS gateway for a read-only invalid-session TLS probe (or DIETER_IOS_SMOKE_HTTPS_GATEWAY)')
    parser.add_argument('--skip-build', action='store_true', help='Use the existing build-for-testing products')
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8]
    evidence = BUILD / 'smoke' / stamp
    evidence.mkdir(parents=True)
    os.chmod(evidence, 0o700)
    if not args.skip_build:
        with (evidence / 'build.log').open('w') as log:
            run('just', 'ios', 'build', stdout=log, stderr=subprocess.STDOUT)
    fixture = BUILD / 'isolated-gateway'
    run('go', 'build', '-o', str(fixture), './scripts/isolated-gateway')
    inventory = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', '-j'], text=True))
    device_type = next((d['identifier'] for d in inventory['devicetypes'] if d['name'] == args.device), None)
    if not device_type:
        raise SystemExit(f'Unavailable simulator type: {args.device}')
    runtime = next((r['identifier'] for r in sorted(inventory['runtimes'], key=lambda r: tuple(int(x) for x in r['version'].split('.')), reverse=True)
                    if r['isAvailable'] and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')), None)
    if not runtime:
        raise SystemExit('An installed iOS Simulator runtime is required')
    simulator = None
    gateway = None
    fixture_log = None
    try:
        simulator = subprocess.check_output(['xcrun', 'simctl', 'create', 'Dieter smoke ' + stamp, device_type, runtime], text=True).strip()
        (evidence / 'simulator.txt').write_text(simulator + '\n')
        # Finish the owned simulator's first boot before XCTest installs its
        # runner or asks accessibility for the first application snapshot.
        with (evidence / 'boot.log').open('w') as log:
            run('xcrun', 'simctl', 'bootstatus', simulator, '-b', timeout=600,
                stdout=log, stderr=subprocess.STDOUT)
        private_gateway_log = evidence / '.gateway-private.log'
        fixture_log = private_gateway_log.open('w+')
        os.chmod(private_gateway_log, 0o600)
        gateway = subprocess.Popen([str(fixture), '--addr', '127.0.0.1:0', '--home', str(evidence / 'fixture'), '--offline-trigger', str(evidence / 'offline')], cwd=ROOT, stdout=fixture_log, stderr=subprocess.STDOUT, start_new_session=True,
                                   env=dict(os.environ, GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='commit.gpgsign', GIT_CONFIG_VALUE_0='false'))
        deadline = time.monotonic() + 60
        values = {}
        while time.monotonic() < deadline:
            if gateway.poll() is not None:
                raise RuntimeError(f'Isolated gateway exited {gateway.returncode}; inspect {evidence}/gateway.log')
            text = private_gateway_log.read_text()
            if '\nREADY\n' in text:
                values = dict(line.split('=', 1) for line in text.splitlines() if line.startswith('DIETER_ISOLATED_'))
                break
            time.sleep(0.2)
        if not values:
            raise RuntimeError('Isolated gateway did not become ready within 60 seconds')
        products = BUILD / 'DerivedData/Build/Products'
        candidates = [path for path in products.glob('*iphonesimulator*.xctestrun') if '-smoke-' not in path.name]
        if not candidates:
            raise RuntimeError('Build-for-testing did not produce an iOS xctestrun file')
        source = max(candidates, key=lambda p: p.stat().st_mtime)
        spec = plistlib.loads(source.read_bytes())
        env = {'DIETER_IOS_TEST_GATEWAY': 'http://' + values['DIETER_ISOLATED_ADDR'],
               'DIETER_IOS_TEST_TOKEN': values['DIETER_ISOLATED_TOKEN'],
               'DIETER_IOS_TEST_DAEMON': values['DIETER_ISOLATED_DAEMON'],
               'DIETER_IOS_TEST_LEGACY_DAEMON': values['DIETER_ISOLATED_LEGACY_DAEMON'],
               'DIETER_IOS_TEST_PROJECT': values['DIETER_ISOLATED_PROJECT'],
               'DIETER_IOS_TEST_BOARD': values['DIETER_ISOLATED_BOARD'],
               'DIETER_IOS_TEST_OFFLINE_TRIGGER': str(evidence / 'offline'),
               'DIETER_IOS_TEST_LANDSCAPE': '1' if args.device.startswith('iPad') else '0'}
        if args.https_gateway:
            if not args.https_gateway.startswith('https://'):
                raise ValueError('--https-gateway must use HTTPS')
            env['DIETER_IOS_TEST_HTTPS_GATEWAY'] = args.https_gateway
        def configure(value):
            if isinstance(value, dict):
                if 'TestBundlePath' in value:
                    value.setdefault('EnvironmentVariables', {}).update(env)
                for child in value.values(): configure(child)
            elif isinstance(value, list):
                for child in value: configure(child)
        configure(spec)
        # __TESTROOT__ is relative to this file; keep the private copy beside products.
        test_run = products / ('DieterIOS-smoke-' + stamp + '.xctestrun')
        test_run.write_bytes(plistlib.dumps(spec))
        os.chmod(test_run, 0o600)
        try:
            with (evidence / 'tests.log').open('w') as log:
                run('xcodebuild', 'test-without-building', '-xctestrun', str(test_run), '-destination', 'platform=iOS Simulator,id=' + simulator,
                    '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(evidence / 'result.xcresult'), stdout=log, stderr=subprocess.STDOUT)
        finally:
            test_run.unlink(missing_ok=True)
            result = evidence / 'result.xcresult'
            if result.exists():
                subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(evidence / 'attachments')], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                summary = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)], cwd=ROOT, capture_output=True, text=True)
                if summary.returncode == 0:
                    (evidence / 'test-summary.json').write_text(summary.stdout)
        summary_file = evidence / 'test-summary.json'
        if not summary_file.exists():
            raise RuntimeError('Xcode did not produce a completed test summary')
        summary = json.loads(summary_file.read_text())
        if summary.get('result') != 'Passed' or summary.get('failedTests', 0) != 0 or summary.get('passedTests', 0) < 1:
            raise RuntimeError(f'Native test suite did not complete successfully; inspect {summary_file}')
        (evidence / 'passed.json').write_text(json.dumps({'device':args.device, 'gateway':'isolated enrolled gateway', 'result':'passed'}, indent=2)+'\n')
        print(f'iOS remote-node smoke passed: {evidence}')
    finally:
        if gateway is not None and gateway.poll() is None:
            gateway.send_signal(signal.SIGINT)
            try: gateway.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(gateway.pid, signal.SIGTERM)
                gateway.wait(timeout=10)
        if fixture_log:
            fixture_log.close()
        if simulator:
            subprocess.run(['xcrun', 'simctl', 'shutdown', simulator], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['xcrun', 'simctl', 'delete', simulator], check=True)
        if fixture_log:
            retain_gateway_log(evidence / '.gateway-private.log', evidence / 'gateway.log')
        print(f'Evidence: {evidence}')


if __name__ == '__main__':
    main()
