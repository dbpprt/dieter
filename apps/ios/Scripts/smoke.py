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
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'apps/ios/.build'
CONSOLE_RAW_LIMIT = 4 * 1024 * 1024
CONSOLE_TEXT_LIMIT = 64 * 1024
CONSOLE_LINE_LIMIT = 400
CONSOLE_EXPORT_TIMEOUT = 15


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def console_text(payload, kind):
    if kind == 'console':
        return '\n'.join(item['content'] for item in payload.get('items', [])
                         if isinstance(item, dict) and isinstance(item.get('content'), str)
                         and item.get('kind') != 'input' and item.get('adaptorType') != 'debugger')
    # XCTest bundles often have no standalone console log. Retain only test
    # output from the action log, never command invocations or launch settings.
    sections = [payload]
    output = []
    while sections:
        section = sections.pop()
        if not isinstance(section, dict):
            continue
        details = section.get('testDetails', {})
        if isinstance(details, dict) and isinstance(details.get('emittedOutput'), str):
            output.append(details['emittedOutput'])
        sections.extend(reversed(section.get('subsections', [])))
    return '\n'.join(output)


def retain_failure_console(result, evidence, token):
    status = 'unavailable: result bundle missing'
    retained = ''
    if result.exists():
        for kind in ('console', 'action'):
            try:
                # Anonymous private storage is closed on every exit. Raw JSON,
                # stderr, command details and environment never become artifacts.
                with tempfile.TemporaryFile() as raw:
                    exported = subprocess.run(
                        ['xcrun', 'xcresulttool', 'get', 'log', '--type', kind,
                         '--compact', '--path', str(result)], cwd=ROOT,
                        stdout=raw, stderr=subprocess.DEVNULL, timeout=CONSOLE_EXPORT_TIMEOUT)
                    if exported.returncode != 0:
                        status = f'unavailable: {kind} export exited {exported.returncode}'
                        continue
                    if raw.tell() > CONSOLE_RAW_LIMIT:
                        status = f'unavailable: {kind} export exceeded size limit'
                        continue
                    raw.seek(0)
                    text = console_text(json.load(raw), kind)
                if not text.strip():
                    status = f'unavailable: {kind} export contained no test console text'
                    continue
                if token:
                    text = text.replace(token, '<redacted>')
                text = re.sub(r'isolated_[0-9a-fA-F]{48}', '<redacted>', text)
                # Redact before truncating so a boundary cannot expose part of a token.
                status = f'retained: {kind} console tail (up to {CONSOLE_LINE_LIMIT} lines)'
                header = status + '\n'
                tail = '\n'.join(text.splitlines()[-CONSOLE_LINE_LIMIT:]).encode('utf-8')
                retained = tail[-(CONSOLE_TEXT_LIMIT - len(header.encode('utf-8'))):].decode('utf-8', errors='ignore')
                break
            except Exception as error:
                status = f'unavailable: {kind} export {type(error).__name__}'
    try:
        destination = evidence / 'failure-console.log'
        destination.write_text(status + '\n' + retained)
        os.chmod(destination, 0o600)
    except OSError:
        status = 'unavailable: diagnostic file could not be written'
    return status


def run_native_tests(test_run, simulator, evidence, token):
    try:
        with (evidence / 'tests.log').open('w') as log:
            run('xcodebuild', 'test-without-building', '-xctestrun', str(test_run),
                '-destination', 'platform=iOS Simulator,id=' + simulator,
                '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(evidence / 'result.xcresult'),
                stdout=log, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        try:
            status = retain_failure_console(evidence / 'result.xcresult', evidence, token)
        except Exception:
            status = 'unavailable: diagnostic collection failed'
        print('Failure console: ' + status)
        raise


def retain_gateway_log(private_log, output_log):
    try:
        text = private_log.read_text(errors='replace')
        for line in text.splitlines():
            if line.startswith('DIETER_ISOLATED_TOKEN='):
                token = line.split('=', 1)[1]
                if token:
                    text = text.replace(token, '<redacted>')
        output_log.write_text(text)
        os.chmod(output_log, 0o600)
    finally:
        private_log.unlink(missing_ok=True)


def stop_gateway(gateway):
    if gateway.poll() is not None:
        return
    # The fixture owns its session. Give it time to close its own children,
    # then bound cleanup even if enrollment or a child process is stuck.
    for sig, timeout in ((signal.SIGINT, 15), (signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        try:
            if sig == signal.SIGINT:
                gateway.send_signal(sig)
            else:
                os.killpg(gateway.pid, sig)
        except ProcessLookupError:
            pass
        try:
            gateway.wait(timeout=timeout)
            return
        except subprocess.TimeoutExpired:
            if sig == signal.SIGKILL:
                raise


def cleanup_resources(gateway, fixture_log, simulator, evidence):
    errors = []

    def attempt(name, operation):
        try:
            operation()
        except Exception as error:
            # Do not print command arguments or fixture credentials on error.
            errors.append(f'{name}: {type(error).__name__}')

    if gateway is not None:
        attempt('stop isolated gateway', lambda: stop_gateway(gateway))
    if fixture_log is not None:
        attempt('close private gateway log', fixture_log.close)
        attempt('retain sanitized gateway log', lambda: retain_gateway_log(
            evidence / '.gateway-private.log', evidence / 'gateway.log'))
    if simulator:
        attempt('shut down owned simulator', lambda: subprocess.run(
            ['xcrun', 'simctl', 'shutdown', simulator], timeout=30,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        attempt('delete owned simulator', lambda: subprocess.run(
            ['xcrun', 'simctl', 'delete', simulator], check=True, timeout=30,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    if errors:
        attempt('write cleanup diagnostics', lambda: (evidence / 'cleanup.log').write_text('\n'.join(errors) + '\n'))
    return errors


def wait_for_gateway(gateway, private_log, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if gateway.poll() is not None:
            raise RuntimeError(f'Isolated gateway exited {gateway.returncode}; inspect gateway.log')
        text = private_log.read_text()
        if '\nREADY\n' in text:
            return dict(line.split('=', 1) for line in text.splitlines() if line.startswith('DIETER_ISOLATED_'))
        time.sleep(0.2)
    raise RuntimeError(f'Isolated gateway did not become ready within {timeout} seconds; inspect gateway.log')


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
    started = time.monotonic()

    def stage(name):
        line = f'{datetime.now(timezone.utc).isoformat()} {time.monotonic() - started:.1f}s {name}'
        with (evidence / 'stage.log').open('a') as log:
            log.write(line + '\n')
        print(line, flush=True)

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
        stage('Creating owned simulator')
        simulator = subprocess.check_output(['xcrun', 'simctl', 'create', 'Dieter smoke ' + stamp, device_type, runtime], text=True).strip()
        (evidence / 'simulator.txt').write_text(simulator + '\n')
        # Establish the fixture before the simulator's expensive first boot.
        # Cold-boot background work must not compete with enrollment startup.
        stage('Starting isolated gateway')
        private_gateway_log = evidence / '.gateway-private.log'
        fixture_log = private_gateway_log.open('w+')
        os.chmod(private_gateway_log, 0o600)
        gateway_environment = dict(os.environ, GIT_CONFIG_COUNT='1',
                                   GIT_CONFIG_KEY_0='commit.gpgsign', GIT_CONFIG_VALUE_0='false')
        harness_runtime = ROOT / 'internal/harness/runtime'
        if (harness_runtime / 'node_modules').is_dir():
            # CI installs this pinned runtime before the smoke journey. Reuse
            # it instead of spending the task-response timeout installing an
            # identical private copy after the fixture replaces HOME.
            gateway_environment['DIETER_HARNESS_RUNTIME_DIR'] = str(harness_runtime)
        gateway = subprocess.Popen([str(fixture), '--addr', '127.0.0.1:0', '--home', str(evidence / 'fixture'), '--offline-trigger', str(evidence / 'offline')], cwd=ROOT, stdout=fixture_log, stderr=subprocess.STDOUT, start_new_session=True,
                                   env=gateway_environment)
        values = wait_for_gateway(gateway, private_gateway_log)
        stage('Isolated gateway ready; booting owned simulator')
        # Finish first boot before XCTest installs its runner or queries AX.
        with (evidence / 'boot.log').open('w') as log:
            run('xcrun', 'simctl', 'bootstatus', simulator, '-b', timeout=600,
                stdout=log, stderr=subprocess.STDOUT)
        stage('Owned simulator ready')
        stage('Loading screenshot share fixture')
        run('xcrun', 'simctl', 'addmedia', simulator,
            str(ROOT / 'apps/android/design/reference/phone-board.png'))
        products = BUILD / 'DerivedData/Build/Products'
        candidates = [path for path in products.glob('*iphonesimulator*.xctestrun') if '-smoke-' not in path.name]
        if not candidates:
            raise RuntimeError('Build-for-testing did not produce an iOS xctestrun file')
        source = max(candidates, key=lambda p: p.stat().st_mtime)
        spec = plistlib.loads(source.read_bytes())
        env = {'DIETER_IOS_TEST_GATEWAY': 'http://' + values['DIETER_ISOLATED_ADDR'],
               'DIETER_IOS_TEST_TOKEN': values['DIETER_ISOLATED_TOKEN'],
               'DIETER_IOS_TEST_DAEMON': values['DIETER_ISOLATED_DAEMON'],
               'DIETER_IOS_TEST_INCOMPATIBLE_DAEMON': values['DIETER_ISOLATED_INCOMPATIBLE_DAEMON'],
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
            stage('Running native tests')
            run_native_tests(test_run, simulator, evidence, values['DIETER_ISOLATED_TOKEN'])
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
        already_failed = sys.exc_info()[0] is not None
        errors = cleanup_resources(gateway, fixture_log, simulator, evidence)
        print(f'Evidence: {evidence}')
        if errors:
            print('Cleanup diagnostics: ' + '; '.join(errors))
            if not already_failed:
                raise RuntimeError('Owned resource cleanup failed; inspect cleanup.log')


if __name__ == '__main__':
    main()
