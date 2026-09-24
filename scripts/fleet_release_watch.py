#!/usr/bin/env python3
"""Publish one bounded, expiring release selection for all managed Macs.

Contains public release metadata only. No Dieter credentials or store access.
Install beside macos_auto_update.py and invoke from the twice-daily systemd timer.
"""
import argparse
import datetime
import json
import os
from pathlib import Path

from macos_auto_update import Deferred, RELEASES, exclusive, fetch, version, write_json


def publish(destination, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    release = json.loads(fetch(RELEASES, 2 * 1024 * 1024))
    tag = release['tag_name']
    version(tag)
    if release.get('draft') or release.get('prerelease'):
        raise Deferred('No stable release available')
    names = ('SHA256SUMS', 'dieter-darwin-arm64.tar.gz', 'Dieter-macOS-arm64.zip')
    assets = []
    for name in names:
        matches = [a for a in release['assets'] if a.get('name') == name]
        expected = f'https://github.com/dbpprt/dieter/releases/download/{tag}/{name}'
        if len(matches) != 1 or matches[0].get('browser_download_url') != expected:
            raise Deferred('Stable release is missing official assets')
        assets.append({'name': name, 'browser_download_url': expected})
    if destination.exists():
        old = json.loads(destination.read_text())
        if version(tag) < version(old['release']['tag_name']):
            raise Deferred('Central release selection cannot move backwards')
    plan = {'protocol': 1, 'checkedAt': now.isoformat(),
            'release': {'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': assets}}
    write_json(destination, plan)
    return tag


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    # Only this public metadata file is served. Never serve the entire state root.
    os.umask(0o022)
    with exclusive(args.output.parent / 'watch.lock'):
        print(publish(args.output))


if __name__ == '__main__':
    main()
