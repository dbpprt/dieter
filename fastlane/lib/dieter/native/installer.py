#!/usr/bin/env python3
"""Build or CI-sign a side-by-side daemon installer without installing it."""

import argparse
import base64
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid


def run(*command, capture=False):
    # Never include argument lists in exceptions: some security arguments are secrets.
    result = subprocess.run(command, capture_output=capture, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}).")
    return result.stdout if capture else None


def release_number(version):
    number = version.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", number):
        raise RuntimeError(
            "RELEASE_VERSION must be a numeric major.minor.patch, optionally prefixed with v."
        )
    return number


def preinstall_script(number):
    # Every version has its own receipt and immutable destination. Refusing existing
    # paths avoids replacing a running executable, without stopping any service.
    return f"""#!/bin/sh
set -eu
volume="${{3:-/}}"
prefix="${{volume%/}}"
for component in usr local libexec dieter {number}; do
    prefix="$prefix/$component"
    if [ -L "$prefix" ]; then
        echo "Dieter cannot install through a symbolic link: $prefix" >&2
        exit 1
    fi
done
if [ -e "$prefix" ]; then
    echo "Dieter {number} is already installed at $prefix. No files or services were changed." >&2
    exit 1
fi
exit 0
"""


def build(package, output, version):
    number = release_number(version)
    package, output = Path(package), Path(output)
    if output.exists() or output.is_symlink():
        raise RuntimeError("Installer output already exists.")
    bundle = package / "DieterPrivacyHelper.app"
    for name in ("dieter", "dieter-capture"):
        source = package / name
        if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK):
            raise RuntimeError(f"Staged {name} must be a regular executable.")
    if not (package / "LICENSE").is_file():
        raise RuntimeError("The staged daemon package is missing LICENSE.")
    helper = bundle / "Contents/MacOS/dieter-privacy"
    if helper.is_symlink() or not helper.is_file() or not os.access(helper, os.X_OK):
        raise RuntimeError("The staged privacy helper must be a regular executable.")
    if (
        bundle.is_symlink()
        or not bundle.is_dir()
        or any(path.is_symlink() for path in bundle.rglob("*"))
    ):
        raise RuntimeError(
            "The staged daemon package must include a regular DieterPrivacyHelper.app bundle."
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dieter-installer-", dir=output.parent) as work:
        work = Path(work)
        payload = work / "root"
        payload.mkdir()
        # Keep shared ancestors out of the BOM: their ownership and permissions
        # may belong to Homebrew and must not be changed by this installer.
        destination = payload
        shutil.copyfile(package / "LICENSE", destination / "LICENSE")
        (destination / "LICENSE").chmod(0o644)
        for name in ("dieter", "dieter-capture"):
            shutil.copy2(package / name, destination / name)
        shutil.copytree(bundle, destination / "DieterPrivacyHelper.app")
        (destination / "INSTALL.txt").write_text(
            f"Dieter {number}\n\n"
            f"CLI: /usr/local/libexec/dieter/{number}/dieter\n"
            "DieterPrivacyHelper.app supplies the separately approved privacy input service.\n"
            "This installer does not start, stop, replace, or configure a daemon service.\n"
            "Homebrew installations and existing daemon services are unchanged.\n"
            "Run the CLI with --help to inspect commands before configuring a service.\n"
            "Each release installs into its own directory; existing versions remain available.\n"
        )
        scripts = work / "scripts"
        scripts.mkdir()
        preinstall = scripts / "preinstall"
        preinstall.write_text(preinstall_script(number))
        preinstall.chmod(0o755)
        staged = work / "Dieter.pkg"
        run(
            "pkgbuild",
            "--root",
            str(payload),
            "--scripts",
            str(scripts),
            "--identifier",
            f"com.dbpprt.dieter.daemon.v{number}",
            "--version",
            number,
            "--install-location",
            f"/usr/local/libexec/dieter/{number}",
            "--ownership",
            "recommended",
            str(staged),
        )
        staged.replace(output)
    print(output)
