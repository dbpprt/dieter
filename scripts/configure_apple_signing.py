#!/usr/bin/env python3
"""Upload dedicated Dieter Apple release credentials to GitHub Actions secrets.

Create new certificates and a team API key for Dieter; this helper never searches
Keychain or discovers/reuses other Apple credentials.
"""

import argparse
import base64
import getpass
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid
import warnings


MAX_SECRET_BYTES = 48 * 1024
MAX_PASSWORD_BYTES = 1024
APPLICATION_PREFIX = "MACOS_DEVELOPER_ID_CERTIFICATE"
INSTALLER_PREFIX = "MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE"


class SetupError(Exception):
    """A safe, credential-free message for the user."""


def run_command(argv, data=None, *, pass_fds=(), label="Command", timeout=30):
    env = os.environ.copy()
    env.pop("GH_DEBUG", None)
    env.pop("GH_HOST", None)
    env["GH_PROMPT_DISABLED"] = "1"
    try:
        result = subprocess.run(argv, input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, pass_fds=pass_fds,
                                env=env, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SetupError(f"{label} could not run. Check the required tools and retry.") from None
    if result.returncode:
        # External output can contain credentials. Never print it or the argv.
        raise SetupError(f"{label} failed. Check the credentials or access and retry.")
    return result.stdout


def read_credential(path, label):
    try:
        with Path(path).expanduser().open("rb") as stream:
            value = stream.read(MAX_SECRET_BYTES + 1)
    except OSError:
        raise SetupError(f"Cannot read {label}.") from None
    if not value or len(base64.b64encode(value)) > MAX_SECRET_BYTES:
        raise SetupError(f"{label} is empty or exceeds GitHub's secret size limit.")
    return value


def read_password_file(path, label):
    descriptor = None
    try:
        descriptor = os.open(Path(path).expanduser(), os.O_RDONLY | os.O_NOFOLLOW)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) & 0o077):
            raise SetupError(f"{label} password file must be owned by you with permissions 600 or 400.")
        value = os.read(descriptor, MAX_PASSWORD_BYTES + 2)
        # Accept the single line ending written by a password manager or editor.
        return value.removesuffix(b"\n").removesuffix(b"\r")
    except OSError:
        raise SetupError(f"Cannot securely read {label} password file.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def password_for(path, label):
    if path:
        password = read_password_file(path, label)
    else:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", getpass.GetPassWarning)
                password = getpass.getpass(f"{label} .p12 password: ").encode("utf-8")
        except (getpass.GetPassWarning, EOFError):
            raise SetupError("A private terminal or a password file is required.") from None
    if not password or len(password) > MAX_PASSWORD_BYTES or any(c in password for c in (b"\n", b"\r", b"\0")):
        raise SetupError(f"{label} password must be a nonempty single line of at most 1024 bytes.")
    return password


def decode_p12(data, password, label, *, legacy=False):
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, password + b"\n")
        os.close(write_fd)
        write_fd = None
        return run_command(
            ["openssl", "pkcs12", "-in", "/dev/stdin", "-passin", f"fd:{read_fd}",
             "-nodes", "-clcerts", *(["-legacy"] if legacy else [])],
            data, pass_fds=(read_fd,), label=label)
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


def validate_p12(data, password, certificate_kind):
    label = f"Developer ID {certificate_kind} certificate"
    try:
        pem = decode_p12(data, password, label)
    except SetupError:
        # Keychain exports may use RC2. OpenSSL 3 needs its legacy provider for
        # these; LibreSSL already supports them in the initial attempt.
        pem = decode_p12(data, password, label, legacy=True)
    certificates = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    keys = re.findall(rb"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----.*?-----END (?:RSA |EC )?PRIVATE KEY-----", pem, re.S)
    if len(certificates) != 1 or len(keys) != 1:
        raise SetupError(f"{label} must contain exactly one signing certificate and its private key.")
    certificate, key = certificates[0], keys[0]
    details = run_command(["openssl", "x509", "-noout", "-subject", "-text", "-checkend", "0"],
                          certificate, label=label)
    oid = b"1.2.840.113635.100.6.1.13" if certificate_kind == "Application" else b"1.2.840.113635.100.6.1.14"
    if oid not in details or f"Developer ID {certificate_kind}:".encode() not in details:
        raise SetupError(f"{label} has the wrong Apple certificate type.")
    public_certificate = run_command(["openssl", "x509", "-pubkey", "-noout"], certificate, label=label)
    public_key = run_command(["openssl", "pkey", "-pubout"], key, label=label)
    if public_certificate != public_key:
        raise SetupError(f"{label} does not match its private key.")
    # Require both signing identities to belong to the same Apple team.
    subject = run_command(["openssl", "x509", "-noout", "-subject", "-nameopt", "sep_multiline"],
                          certificate, label=label)
    team = re.search(rb"(?m)^\s*OU\s*=\s*([A-Z0-9]{10})\s*$", subject)
    if not team:
        raise SetupError(f"{label} has no Apple team identifier.")
    return team.group(1)


def build_secrets(args):
    application = read_credential(args.application_p12, "Application .p12")
    installer = read_credential(args.installer_p12, "Installer .p12")
    notary = read_credential(args.notary_key, "App Store Connect .p8")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.key_id):
        raise SetupError("The App Store Connect Key ID must be 10 uppercase letters or digits.")
    try:
        issuer = str(uuid.UUID(args.issuer_id))
    except ValueError:
        raise SetupError("The App Store Connect Issuer ID must be a UUID.") from None
    if not notary.strip().startswith(b"-----BEGIN PRIVATE KEY-----"):
        raise SetupError("The App Store Connect .p8 must contain an unencrypted private key.")
    run_command(["openssl", "pkey", "-check", "-noout"], notary, label="App Store Connect private key")
    notary_public = run_command(["openssl", "pkey", "-pubout"], notary, label="App Store Connect private key")
    notary_curve = run_command(["openssl", "ec", "-pubin", "-text", "-noout"],
                              notary_public, label="App Store Connect P-256 key")
    if b"ASN1 OID: prime256v1" not in notary_curve:
        raise SetupError("The App Store Connect .p8 must use Apple's P-256 key type.")
    application_password = password_for(args.application_password_file, "Application")
    installer_password = password_for(args.installer_password_file, "Installer")
    application_team = validate_p12(application, application_password, "Application")
    installer_team = validate_p12(installer, installer_password, "Installer")
    if application_team != installer_team:
        raise SetupError("Application and Installer certificates must belong to the same Apple team.")
    return {
        APPLICATION_PREFIX + "_BASE64": base64.b64encode(application),
        APPLICATION_PREFIX + "_PASSWORD": application_password,
        INSTALLER_PREFIX + "_BASE64": base64.b64encode(installer),
        INSTALLER_PREFIX + "_PASSWORD": installer_password,
        "MACOS_NOTARY_KEY_BASE64": base64.b64encode(notary),
        "MACOS_NOTARY_KEY_ID": args.key_id.encode("ascii"),
        "MACOS_NOTARY_ISSUER_ID": issuer.encode("ascii"),
    }


def list_secrets(repo):
    output = run_command(["gh", "secret", "list", "--repo", repo, "--json", "name"],
                         label="GitHub repository secret access")
    try:
        return {item["name"] for item in json.loads(output)}
    except (ValueError, KeyError, TypeError):
        raise SetupError("GitHub returned an invalid secret listing.") from None


def upload_secrets(repo, secrets):
    # Pin GitHub.com even when the caller has an enterprise GH_HOST configured.
    target = f"https://github.com/{repo}"
    run_command(["gh", "auth", "status", "--hostname", "github.com"], label="GitHub authentication")
    list_secrets(target)
    for name, value in secrets.items():
        run_command(["gh", "secret", "set", name, "--repo", target], value,
                    label=f"Uploading {name}")
        print(f"Uploaded {name}", flush=True)
    if not secrets.keys() <= list_secrets(target):
        raise SetupError("Some uploaded secret names were not returned by GitHub. Retry setup to complete it.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--repo", default="dbpprt/dieter", help="GitHub.com owner/repository receiving release secrets")
    parser.add_argument("--application-p12", required=True, help="Dedicated Dieter Developer ID Application certificate and private key export")
    parser.add_argument("--installer-p12", required=True, help="Dedicated Dieter Developer ID Installer certificate and private key export")
    parser.add_argument("--notary-key", required=True, help="Dedicated Dieter App Store Connect team API private key (.p8)")
    parser.add_argument("--key-id", required=True, help="App Store Connect API Key ID")
    parser.add_argument("--issuer-id", required=True, help="App Store Connect team API Issuer ID")
    parser.add_argument("--application-password-file", help="Private file containing the Application export password; otherwise prompt securely")
    parser.add_argument("--installer-password-file", help="Private file containing the Installer export password; otherwise prompt securely")
    parser.add_argument("--check", action="store_true", help="Validate local inputs only; do not contact GitHub or upload secrets")
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
            raise SetupError("The repository must be a GitHub.com owner/repository name.")
        secrets = build_secrets(args)
        if args.check:
            print("Apple signing credentials passed local validation. Nothing uploaded.")
        else:
            upload_secrets(args.repo, secrets)
            print("Apple signing secrets configured successfully.")
        return 0
    except SetupError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCanceled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
