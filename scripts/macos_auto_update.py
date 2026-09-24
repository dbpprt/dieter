#!/usr/bin/env python3
"""Opt-in, twice-daily signed Dieter app/daemon updates for macOS arm64.

No store migrations or resets. Releases without the offline safety probe are
ineligible. All persistent updater state lives in DIETER_HOME/auto-update.
"""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import posixpath
import stat
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

LABEL = 'com.dbpprt.dieter.auto-update'
RELEASES = 'https://api.github.com/repos/dbpprt/dieter/releases/latest'
TEAM = 'DS6N5L85E7'


class Deferred(Exception):
    pass


def run(*args, timeout=60):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True,
                            timeout=timeout, stdin=subprocess.DEVNULL)
    if result.returncode:
        # Do not put command arguments, credentials, or transcript output in logs.
        raise Deferred(f'{Path(str(args[0])).name} failed (exit {result.returncode})')
    return result.stdout


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sync_tree(root):
    for directory, _, files in os.walk(root, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            with path.open('rb') as source:
                os.fsync(source.fileno())
        sync_directory(directory)


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as output:
        json.dump(value, output, indent=2)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)
    sync_directory(path.parent)


def version(value):
    if not re.fullmatch(r'v?\d+\.\d+\.\d+', value):
        raise Deferred('Release is not a stable numeric version')
    return tuple(map(int, value.removeprefix('v').split('.')))


def fetch(url, limit):
    request = urllib.request.Request(url, headers={'User-Agent': 'Dieter-safe-updater'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise Deferred('Release download exceeds safety limit')
    return data


def signed(path, identifier):
    requirement = (f'identifier "{identifier}" and anchor apple generic and '
                   f'certificate leaf[subject.OU] = "{TEAM}" and '
                   'certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement, path)


def probe(binary, root, expected, api):
    try:
        result = json.loads(run(binary, '__update-preflight', '--root', root))
    except (Deferred, ValueError) as error:
        raise Deferred('Release has no successful read-only data compatibility probe; keeping current version') from error
    if result.get('protocol') != 1 or version(result.get('version', '')) != version(expected):
        raise Deferred('Release safety probe identity does not match the download')
    if result.get('apiVersion') != api:
        raise Deferred('Release changes API compatibility; coordinated manual update required')


def app_version(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        return plistlib.load(source)['CFBundleShortVersionString']


def app_running():
    result = subprocess.run(['/usr/bin/pgrep', '-x', 'DieterMac'], capture_output=True)
    if result.returncode not in (0, 1):
        raise Deferred('Cannot determine whether Dieter is open')
    return result.returncode == 0


@contextlib.contextmanager
def exclusive(path):
    with path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def snapshot(root, destination):
    """Stopped store only; exclude updater itself, never follow external symlinks."""
    destination.mkdir()
    for child in root.iterdir():
        if child.name == 'auto-update':
            continue
        if child.is_symlink():
            os.symlink(os.readlink(child), destination / child.name)
        elif child.is_dir():
            shutil.copytree(child, destination / child.name, symlinks=True)
        elif child.is_file():
            shutil.copy2(child, destination / child.name)
        else:
            raise Deferred('Unexpected special file in store; backup aborted')


def payload(release, work):
    assets = {a['name']: a['browser_download_url'] for a in release['assets']}
    names = ('SHA256SUMS', 'dieter-darwin-arm64.tar.gz', 'Dieter-macOS-arm64.zip')
    for name in names:
        url = assets.get(name, '')
        if not url.startswith('https://github.com/dbpprt/dieter/releases/download/'):
            raise Deferred('Missing official release assets')
        (work / name).write_bytes(fetch(url, 500 * 1024 * 1024 if name != 'SHA256SUMS' else 1024 * 1024))
    hashes = {}
    for line in (work / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        hashes[name.lstrip('*')] = digest
    for name in names[1:]:
        if hashlib.sha256((work / name).read_bytes()).hexdigest() != hashes.get(name):
            raise Deferred('Release checksum mismatch')
    daemon = work / 'daemon'
    daemon.mkdir()
    with tarfile.open(work / names[1]) as archive:
        for name in ('dieter', 'dieter-capture'):
            matches = [m for m in archive.getmembers() if Path(m.name).name == name]
            if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 300 * 1024 * 1024:
                raise Deferred('Invalid daemon archive')
            with archive.extractfile(matches[0]) as source:
                (daemon / name).write_bytes(source.read())
            (daemon / name).chmod(0o755)
    # ditto preserves framework symlinks needed by the signed native application.
    # Reject traversal before passing the archive to the system extractor.
    import zipfile
    with zipfile.ZipFile(work / names[2]) as archive:
        if sum(i.file_size for i in archive.infolist()) > 2 * 1024**3:
            raise Deferred('Application archive is too large')
        for info in archive.infolist():
            p = Path(info.filename)
            if p.is_absolute() or '..' in p.parts:
                raise Deferred('Unsafe application archive')
            if stat.S_ISLNK(info.external_attr >> 16):
                target = archive.read(info).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(str(p.parent), target))
                if target.startswith('/') or resolved == '..' or resolved.startswith('../'):
                    raise Deferred('Unsafe application symlink')
    run('/usr/bin/ditto', '-x', '-k', work / names[2], work / 'app', timeout=180)
    apps = list((work / 'app').rglob('Dieter.app'))
    if len(apps) != 1:
        raise Deferred('Release must contain exactly one Dieter.app')
    signed(daemon / 'dieter', 'com.dbpprt.dieter.daemon')
    signed(daemon / 'dieter-capture', 'com.dbpprt.dieter.capture')
    signed(apps[0], 'com.dbpprt.dieter.mac')
    run('/usr/sbin/spctl', '--assess', '--type', 'execute', apps[0], timeout=120)
    if version(app_version(apps[0])) != version(release['tag_name']):
        raise Deferred('App version does not match daemon release')
    return daemon, apps[0]


class Updater:
    def __init__(self, config):
        self.root = Path(config['root'])
        self.state = self.root / 'auto-update'
        self.runtime = Path(config['runtime'])
        self.app = Path(config['app'])
        self.plist = Path(config['servicePlist'])
        with self.plist.open('rb') as source:
            self.service = plistlib.load(source)
        args = self.service.get('ProgramArguments', [])
        if not all(os.access(path, os.W_OK) for path in (self.root, self.runtime, self.runtime.parent, self.app)):
            raise Deferred('Updater needs writable data, service runtime and app bundle')
        if args[:3] != [str(self.runtime / 'bin/dieter'), 'daemon', 'start']:
            raise Deferred('LaunchAgent must run the configured daemon directly')
        self.fixed = '--runtime' in args
        if self.fixed:
            offset = args.index('--runtime') + 1
            if offset == len(args) or Path(args[offset]).resolve() != self.runtime:
                raise Deferred('Daemon LaunchAgent uses a different service runtime')
        else:
            for name in ('dieter', 'dieter-capture'):
                binary = self.runtime / 'bin' / name
                if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.W_OK):
                    raise Deferred('Manual installs require a writable, regular daemon/helper pair')
        self.target = f'gui/{os.getuid()}/{self.service["Label"]}'

    def backup_runtime(self, destination):
        if self.fixed:
            shutil.copytree(self.runtime, destination, symlinks=True)
        else:
            # A manual prefix can contain unrelated tools. Never snapshot or
            # replace the whole prefix when updating its Dieter pair.
            (destination / 'bin').mkdir(parents=True)
            for name in ('dieter', 'dieter-capture'):
                shutil.copy2(self.runtime / 'bin' / name, destination / 'bin' / name)

    def replace_manual_pair(self, source):
        for name in ('dieter', 'dieter-capture'):
            destination = self.runtime / 'bin' / name
            with tempfile.NamedTemporaryFile(prefix='.dieter-update-', dir=destination.parent, delete=False) as output:
                temporary = Path(output.name)
            try:
                shutil.copy2(source / name, temporary)
                with temporary.open('rb') as content:
                    os.fsync(content.fileno())
                temporary.replace(destination)
                sync_directory(destination.parent)
            finally:
                temporary.unlink(missing_ok=True)

    def status(self):
        return json.loads(run(self.runtime / 'bin/dieter', '--store', self.root,
                              'daemon', 'status', '--format', 'json'))

    def stop(self):
        run('/bin/launchctl', 'bootout', self.target, timeout=60)
        # Never copy a live store or bypass an active daemon's lifetime lock.
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            try:
                with exclusive(self.root / 'runtime/daemon.lock'):
                    return
            except BlockingIOError:
                time.sleep(1)
        raise Deferred('Daemon did not stop safely')

    def start(self):
        run('/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', self.plist)

    def healthy(self, expected):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                status = self.status()
                if (status.get('apiHealthy') and version(status.get('version', '')) == version(expected)
                        and (not status.get('enrolled') or status.get('gatewayState') == 'connected')):
                    return
            except (Deferred, ValueError):
                pass
            time.sleep(2)
        raise Deferred('Updated daemon did not become healthy')

    def recover(self):
        journal = self.state / 'transaction.json'
        if not journal.exists():
            return
        tx = json.loads(journal.read_text())
        backup = Path(tx['backup'])
        # A committed transaction only needs journal cleanup.
        if tx.get('committed'):
            journal.unlink()
            return
        loaded = subprocess.run(['/bin/launchctl', 'print', self.target], capture_output=True).returncode == 0
        if not tx.get('backupsComplete'):
            # No binaries were changed; a partial snapshot must never be restored.
            if not loaded:
                self.start()
            self.healthy(tx['previous'])
            journal.unlink()
            raise Deferred('Update stopped before activation; original service retained')
        if not all((backup / name).is_dir() for name in ('runtime', 'Contents', 'data')):
            raise Deferred('Recovery backup is incomplete; manual recovery required')
        if app_running():
            raise Deferred('Quit Dieter to recover the interrupted update; data is retained')
        # If no process owns the store, bootout can report "not loaded".
        if loaded:
            self.stop()
        with exclusive(self.root / 'runtime/daemon.lock'):
            if app_running():
                raise Deferred('Quit Dieter to finish recovering the interrupted update')
            if (backup / 'runtime').exists():
                # Store data is NEVER replaced: it may contain work after activation.
                if self.fixed:
                    if self.runtime.exists():
                        shutil.rmtree(self.runtime)
                    shutil.copytree(backup / 'runtime', self.runtime, symlinks=True)
                else:
                    self.replace_manual_pair(backup / 'runtime/bin')
            if (backup / 'Contents').exists():
                contents = self.app / 'Contents'
                if contents.exists():
                    shutil.rmtree(contents)
                shutil.copytree(backup / 'Contents', contents, symlinks=True)
        self.start()
        self.healthy(tx['previous'])
        journal.unlink()
        raise Deferred('Recovered previous app and daemon; data and backup retained')

    def idle(self):
        binary = self.runtime / 'bin/dieter'
        # Unscoped card list only includes the selected project. Enumerate every
        # project, including archived cards, so hidden work cannot be missed.
        projects = json.loads(run(binary, '--store', self.root, 'project', 'list', '--format', 'json'))
        commands = [('chat', 'list', '--archived')]
        for project in projects.get('projects', []):
            commands.extend([('card', 'list', '--project', project['id']),
                             ('card', 'list', '--project', project['id'], '--archived')])
        for command in commands:
            items = json.loads(run(binary, '--store', self.root, *command, '--format', 'json')) or []
            if any(item.get('runtime', 'idle') not in ('idle', 'failed', '') for item in items):
                raise Deferred('An agent is active; update deferred')
        for group, key, finished in (('terminal', 'terminals', ('exited',)),
                                      ('remote', 'executions', ('exited', 'canceled', 'timed_out', 'closed'))):
            response = json.loads(run(binary, '--store', self.root, group, 'list', '--format', 'json'))
            if any(item.get('status') not in finished for item in response.get(key, [])):
                raise Deferred('A terminal or remote command is active; update deferred')
        screens = json.loads(run(binary, '--store', self.root, 'screen', 'sessions'))
        if screens.get('sessions'):
            raise Deferred('Screen sharing is active; update deferred')

    def check(self):
        self.recover()
        release = json.loads(fetch(RELEASES, 2 * 1024 * 1024))
        latest = release['tag_name']
        if release.get('draft') or release.get('prerelease'):
            raise Deferred('No stable release available')
        current = self.status()
        if Path(current.get('store', '')).resolve() != self.root:
            raise Deferred('Daemon data path differs from updater configuration')
        if not current.get('apiHealthy'):
            raise Deferred('Current daemon is not healthy; repair it before enabling automatic activation')
        if version(latest) <= version(current['version']) and version(latest) <= version(app_version(self.app)):
            return 'up-to-date', current['version']
        if version(latest) < max(version(current['version']), version(app_version(self.app))):
            raise Deferred('Automatic downgrades are not allowed')
        if app_running():
            raise Deferred(f'{latest} is available; waiting until Dieter is closed')
        if current.get('enrolled') and current.get('gatewayState') != 'connected':
            raise Deferred('Gateway is disconnected; retaining the current installation')
        self.idle()
        live = json.loads(run(self.runtime / 'bin/dieter', '--store', self.root, 'status', '--format', 'json'))
        api = live['health']['version']
        with tempfile.TemporaryDirectory(prefix='download-', dir=self.state) as directory:
            daemon, app = payload(release, Path(directory))
            probe(daemon / 'dieter', self.root, latest, api)
            if app_running():
                raise Deferred(f'{latest} is compatible; quit Dieter before a scheduled check to install it')
            if current.get('enrolled') and current.get('gatewayState') != 'connected':
                raise Deferred('Gateway is disconnected; retaining the current installation')
            if any((self.runtime / n).exists() for n in ('pending', 'candidate', 'activation.json')):
                raise Deferred('Another daemon update is pending')
            # Harness preparation only touches the content-addressed runtime cache.
            run(daemon / 'dieter', '__harness-prepare', '--root', self.root, timeout=600)
            self.idle()
            self.activate(daemon, app, latest, current['version'])
        return 'updated', latest

    def activate(self, daemon, app, latest, previous):
        # Backups are never automatically pruned. Refuse insufficient space.
        required = sum(p.stat().st_size for p in self.root.rglob('*')
                       if p.is_file() and not p.is_symlink() and self.state not in p.parents)
        if shutil.disk_usage(self.root).free < required + 3 * 1024**3:
            raise Deferred('Not enough space for a complete backup and update')
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup = self.state / 'backups' / stamp
        backup.mkdir(parents=True)
        journal = self.state / 'transaction.json'
        tx = {'backup': str(backup), 'previous': previous, 'target': latest}
        # Journal before stopping: power loss must restart the original service.
        write_json(journal, tx)
        try:
            self.stop()
            with exclusive(self.root / 'runtime/daemon.lock'):
                if app_running():
                    raise Deferred('Dieter was opened during the update check')
                snapshot(self.root, backup / 'data')
                self.backup_runtime(backup / 'runtime')
                shutil.copytree(self.app / 'Contents', backup / 'Contents', symlinks=True)
                sync_tree(backup)
                sync_directory(backup.parent)
                # Backups must be complete before recovery is allowed to use them.
                tx['backupsComplete'] = True
                write_json(journal, tx)
                if self.fixed:
                    run(daemon / 'dieter', '__service-stage', '--root', self.runtime)
                else:
                    self.replace_manual_pair(daemon)
                staged = self.app / 'UpdateContents'
                if staged.exists():
                    raise Deferred('Application has an unfinished manual update')
                shutil.copytree(app / 'Contents', staged, symlinks=True)
                shutil.rmtree(self.app / 'Contents')
                sync_tree(staged)
                staged.rename(self.app / 'Contents')
                sync_directory(self.app)
                signed(self.app, 'com.dbpprt.dieter.mac')
            self.start()
            self.healthy(latest)
            tx['committed'] = True
            write_json(journal, tx)
            journal.unlink()
        except BaseException:
            # Recovery also runs at the next check after power loss or SIGKILL.
            self.recover()
            raise


def launch_agent(script, config, python):
    return {'Label': LABEL, 'ProgramArguments': [python, str(script), 'run', '--config', str(config)],
            'StartCalendarInterval': [{'Hour': 9, 'Minute': 0}, {'Hour': 21, 'Minute': 0}],
            'RunAtLoad': True, 'ProcessType': 'Background',
            'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('install', 'run', 'status', 'uninstall'))
    parser.add_argument('--root', type=Path, default=Path(os.environ.get('DIETER_HOME', Path.home() / '.dieter')))
    parser.add_argument('--runtime', type=Path, default=Path('/opt/homebrew/var/dieter/service'))
    parser.add_argument('--app', type=Path, default=Path('/Applications/Dieter.app'))
    parser.add_argument('--service-plist', type=Path, default=Path.home() / 'Library/LaunchAgents/sh.brew.dieter.plist')
    parser.add_argument('--config', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    state = args.root.resolve() / 'auto-update'
    config = args.config or state / 'config.json'
    agent = Path.home() / f'Library/LaunchAgents/{LABEL}.plist'
    if args.command == 'status':
        print((config.parent / 'status.json').read_text())
        return
    if args.command == 'uninstall':
        # Never terminate an updater in the middle of its transaction.
        with exclusive(config.parent / 'check.lock'):
            subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{LABEL}'], capture_output=True)
            agent.unlink(missing_ok=True)
        print('Schedule removed; data and backups retained.')
        return
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise Deferred('Automatic updates currently support macOS arm64 only')
    if args.command == 'install':
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with exclusive(state / 'check.lock'):
            settings = {'root': str(args.root.resolve()), 'runtime': str(args.runtime.resolve()),
                        'app': str(args.app.resolve()), 'servicePlist': str(args.service_plist.resolve())}
            Updater(settings)  # Reject unsupported configurations before scheduling.
            write_json(config, settings)
            script = state / 'updater.py'
            shutil.copy2(__file__, script)
            agent.parent.mkdir(parents=True, exist_ok=True)
            agent.write_bytes(plistlib.dumps(launch_agent(script, config, sys.executable)))
            subprocess.run(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{LABEL}'], capture_output=True)
        run('/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', agent)
        print('Installed: checks at 09:00 and 21:00 local time, and login. Backups are retained.')
        return
    settings = json.loads(config.read_text())
    state = Path(settings['root']) / 'auto-update'
    with exclusive(state / 'check.lock'):
        try:
            outcome, detail = Updater(settings).check()
        except Exception as error:
            outcome, detail = 'deferred', str(error)
        write_json(state / 'status.json', {'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                                          'state': outcome, 'detail': detail})
        print(f'{outcome}: {detail}')


if __name__ == '__main__':
    main()
