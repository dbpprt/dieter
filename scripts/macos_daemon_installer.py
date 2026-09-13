#!/usr/bin/env python3
"""Build or CI-sign a side-by-side daemon installer without installing it."""

import argparse
import base64
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

from macos_notary_submit import submit


def run(*command, capture=False):
    # Never include argument lists in exceptions: some security arguments are secrets.
    result = subprocess.run(command, capture_output=capture, text=True)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed (exit {result.returncode}).")
    return result.stdout if capture else None


def release_number(version):
    number = version.removeprefix("v")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", number):
        raise RuntimeError("RELEASE_VERSION must be a numeric major.minor.patch, optionally prefixed with v.")
    return number


def preinstall_script(number):
    # Every version has its own receipt and immutable destination. Refusing existing
    # paths avoids replacing a running executable, without stopping any service.
    return f'''#!/bin/sh
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
'''


def build(package, output, version):
    number = release_number(version)
    package, output = Path(package), Path(output)
    if output.exists() or output.is_symlink():
        raise RuntimeError("Installer output already exists.")
    for name in ("dieter", "dieter-capture"):
        source = package / name
        if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK):
            raise RuntimeError(f"Staged {name} must be a regular executable.")
    if not (package / "LICENSE").is_file():
        raise RuntimeError("The staged daemon package is missing LICENSE.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dieter-installer-", dir=output.parent) as work:
        work = Path(work)
        payload = work / "root"
        payload.mkdir()
        # Keep shared ancestors out of the BOM: their ownership and permissions
        # may belong to Homebrew and must not be changed by this installer.
        destination = payload
        for name in ("dieter", "dieter-capture", "LICENSE"):
            shutil.copyfile(package / name, destination / name)
            (destination / name).chmod(0o644 if name == "LICENSE" else 0o755)
        (destination / "INSTALL.txt").write_text(
            f"Dieter {number}\n\n"
            f"CLI: /usr/local/libexec/dieter/{number}/dieter\n"
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
        run("pkgbuild", "--root", str(payload), "--scripts", str(scripts),
            "--identifier", f"com.dbpprt.dieter.daemon.v{number}", "--version", number,
            "--install-location", f"/usr/local/libexec/dieter/{number}",
            "--ownership", "recommended", str(staged))
        staged.replace(output)
    print(output)


def secret_file(path, encoded):
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        raise RuntimeError("A signing credential is not valid base64.") from error
    with path.open("xb") as handle:
        path.chmod(0o600)
        handle.write(decoded)


def sign(output):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("Installer signing and notarization are CI-only.")
    names = ("INSTALLER_CERTIFICATE_BASE64", "INSTALLER_CERTIFICATE_PASSWORD", "NOTARY_KEY_BASE64",
             "NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "RUNNER_TEMP")
    for name in names:
        if not os.environ.get(name):
            raise RuntimeError(f"{name} is required.")
    output = Path(output)
    if output.is_symlink() or not output.is_file():
        raise RuntimeError("The unsigned installer must be a regular file.")
    with tempfile.TemporaryDirectory(prefix="dieter-installer-signing-", dir=os.environ["RUNNER_TEMP"]) as work:
        work = Path(work)
        keychain = work / "signing.keychain-db"
        certificate = work / "developer-id-installer.p12"
        notary_key = work / "notary-key.p8"
        keychain_password = str(uuid.uuid4())
        created = False
        try:
            secret_file(certificate, os.environ["INSTALLER_CERTIFICATE_BASE64"])
            secret_file(notary_key, os.environ["NOTARY_KEY_BASE64"])
            run("security", "create-keychain", "-p", keychain_password, str(keychain), capture=True)
            created = True
            run("security", "set-keychain-settings", "-lut", "21600", str(keychain), capture=True)
            run("security", "unlock-keychain", "-p", keychain_password, str(keychain), capture=True)
            run("security", "import", str(certificate), "-k", str(keychain),
                "-P", os.environ["INSTALLER_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/productsign", capture=True)
            run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s",
                "-k", keychain_password, str(keychain), capture=True)
            identities = run("security", "find-identity", "-v", str(keychain), capture=True)
            matches = re.findall(r'"(Developer ID Installer:[^"\n]+)"', identities)
            if len(matches) != 1:
                raise RuntimeError("The temporary keychain must contain one Developer ID Installer identity.")
            signed = work / "Dieter.pkg"
            run("productsign", "--sign", matches[0], "--keychain", str(keychain), str(output), str(signed))
            run("pkgutil", "--check-signature", str(signed))
            submit(signed, notary_key, os.environ["NOTARY_KEY_ID"], os.environ["NOTARY_ISSUER_ID"])
            run("xcrun", "stapler", "staple", str(signed))
            run("xcrun", "stapler", "validate", str(signed))
            run("pkgutil", "--check-signature", str(signed))
            run("spctl", "--assess", "--type", "install", "--verbose=2", str(signed))
            # Stage beside the output so publication is atomic even across volumes.
            with tempfile.NamedTemporaryFile(prefix=".dieter-signed-", dir=output.parent, delete=False) as handle:
                replacement = Path(handle.name)
            try:
                shutil.copyfile(signed, replacement)
                replacement.chmod(0o644)
                replacement.replace(output)
            finally:
                replacement.unlink(missing_ok=True)
        finally:
            if created:
                subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)
    print(f"Signed, notarized, and stapled {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package = commands.add_parser("build", help="Build an unsigned package without installing it.")
    package.add_argument("--package", default="stage/dieter-darwin-arm64")
    package.add_argument("--output", default="dist/dieter-darwin-arm64.pkg")
    package.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""))
    signing = commands.add_parser("sign", help="CI-only Developer ID Installer signing and notarization.")
    signing.add_argument("--output", default="dist/dieter-darwin-arm64.pkg")
    args = parser.parse_args()
    try:
        if platform.system() != "Darwin":
            raise RuntimeError("macOS installer packaging requires Darwin.")
        if args.command == "build":
            build(args.package, args.output, args.version)
        else:
            sign(args.output)
    except (RuntimeError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
