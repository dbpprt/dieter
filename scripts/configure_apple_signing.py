#!/usr/bin/env python3
"""Upload dedicated Dieter Apple release credentials to GitHub Actions secrets.

Create new certificates and a team API key for Dieter; this helper never searches
Keychain or discovers/reuses other Apple credentials.
"""

import argparse
import base64
from datetime import datetime, timezone
import getpass
import json
import os
from pathlib import Path
import plistlib
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


def run_command(argv, data=None, *, pass_fds=(), label="Command", timeout=30, include_stderr=False):
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
    return result.stdout + result.stderr if include_stderr else result.stdout


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


def decode_p12(data, password, label, *, legacy=False, info=False):
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, password + b"\n")
        os.close(write_fd)
        write_fd = None
        return run_command(
            ["openssl", "pkcs12", "-in", "/dev/stdin", "-passin", f"fd:{read_fd}",
             *(["-info", "-noout"] if info else ["-nodes", "-clcerts"]),
             *(["-legacy"] if legacy else [])],
            data, pass_fds=(read_fd,), label=label, include_stderr=info)
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


def validate_signing_identity(data, password, label, oid, subject_prefix):
    """Read a dedicated PKCS#12 identity without importing it into Keychain."""
    if not password or len(password) > MAX_PASSWORD_BYTES or any(c in password for c in (b"\n", b"\r", b"\0")):
        raise SetupError(f"{label} password must be a nonempty single line of at most 1024 bytes.")
    legacy = False
    try:
        pem = decode_p12(data, password, label)
    except SetupError:
        # Keychain exports may use RC2. OpenSSL 3 needs its legacy provider for
        # these; LibreSSL already supports them in the initial attempt.
        legacy = True
        pem = decode_p12(data, password, label, legacy=True)
    algorithms = decode_p12(data, password, label, legacy=legacy, info=True)
    # OpenSSL successfully reads its own PBES2/AES/SHA-256 defaults, while
    # Apple's SecPKCS12Import reports a misleading "MAC verification failed".
    # Inspect metadata without printing it or importing into the user's keychain.
    mac = re.search(rb"(?im)^MAC:\s*([^,\s]+)", algorithms)
    if (b"PBES2" in algorithms or b"PBKDF2" in algorithms
            or (mac is not None and mac.group(1).lower() != b"sha1")):
        raise SetupError(
            f"{label} uses PKCS#12 defaults incompatible with macOS import. "
            "Re-export from Keychain Access, or use OpenSSL export options "
            "-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1. "
            "See docs/apple-release-signing.md.")
    certificates = re.findall(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    keys = re.findall(rb"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----.*?-----END (?:RSA |EC )?PRIVATE KEY-----", pem, re.S)
    if len(certificates) != 1 or len(keys) != 1:
        raise SetupError(f"{label} must contain exactly one signing certificate and its private key.")
    certificate, key = certificates[0], keys[0]
    details = run_command(["openssl", "x509", "-noout", "-subject", "-text", "-checkend", "0"],
                          certificate, label=label)
    if oid not in details or subject_prefix not in details:
        raise SetupError(f"{label} has the wrong Apple certificate type.")
    public_certificate = run_command(["openssl", "x509", "-pubkey", "-noout"], certificate, label=label)
    public_key = run_command(["openssl", "pkey", "-pubout"], key, label=label)
    if public_certificate != public_key:
        raise SetupError(f"{label} does not match its private key.")
    # Require both signing identities to belong to the same Apple team.
    subject = run_command(["openssl", "x509", "-noout", "-subject", "-nameopt", "sep_multiline"],
                          certificate, label=label)
    common_name = re.search(rb"(?m)^\s*CN\s*=\s*(.+)$", subject)
    if not common_name or not common_name.group(1).startswith(subject_prefix):
        raise SetupError(f"{label} has the wrong Apple certificate type.")
    team = re.search(rb"(?m)^\s*OU\s*=\s*([A-Z0-9]{10})\s*$", subject)
    if not team:
        raise SetupError(f"{label} has no Apple team identifier.")
    validity = run_command(["openssl", "x509", "-noout", "-startdate"], certificate, label=label)
    try:
        not_before = datetime.strptime(validity.decode("ascii").strip(), "notBefore=%b %d %H:%M:%S %Y GMT")
    except (ValueError, UnicodeDecodeError):
        raise SetupError(f"{label} has no valid start date.") from None
    if not_before.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc):
        raise SetupError(f"{label} is not yet valid.")
    return certificate, team.group(1)


def validate_p12(data, password, certificate_kind):
    oid = b"1.2.840.113635.100.6.1.13" if certificate_kind == "Application" else b"1.2.840.113635.100.6.1.14"
    _, team = validate_signing_identity(
        data, password, f"Developer ID {certificate_kind} certificate", oid,
        f"Developer ID {certificate_kind}:".encode())
    return team


def validate_api_key(api_key, key_id, issuer_id):
    if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
        raise SetupError("The App Store Connect Key ID must be 10 uppercase letters or digits.")
    try:
        issuer = str(uuid.UUID(issuer_id))
    except ValueError:
        raise SetupError("The App Store Connect Issuer ID must be a UUID.") from None
    if not api_key.strip().startswith(b"-----BEGIN PRIVATE KEY-----"):
        raise SetupError("The App Store Connect .p8 must contain an unencrypted private key.")
    run_command(["openssl", "pkey", "-check", "-noout"], api_key, label="App Store Connect private key")
    notary_public = run_command(["openssl", "pkey", "-pubout"], api_key, label="App Store Connect private key")
    notary_curve = run_command(["openssl", "ec", "-pubin", "-text", "-noout"],
                              notary_public, label="App Store Connect P-256 key")
    if b"ASN1 OID: prime256v1" not in notary_curve:
        raise SetupError("The App Store Connect .p8 must use Apple's P-256 key type.")
    return issuer


def validate_ios_material(distribution_p12, distribution_password, provisioning_profile,
                          api_key, key_id, issuer_id, bundle_id, *, team_id=None):
    """Validate dedicated iOS release material locally; return non-secret metadata.

    CMS signature integrity is checked without contacting Apple. Account roles,
    certificate revocation, and App Store Connect access are verified at upload.
    The helper never discovers credentials or imports a Keychain identity.
    """
    if (not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id)
            or len(bundle_id) > 255):
        raise SetupError("The iOS bundle ID must be an explicit reverse-DNS identifier without wildcards.")
    issuer = validate_api_key(api_key, key_id, issuer_id)
    certificate, certificate_team = validate_signing_identity(
        distribution_p12, distribution_password, "Apple Distribution certificate",
        b"1.2.840.113635.100.6.1.4", b"Apple Distribution:")
    team = certificate_team.decode("ascii")
    if team_id is not None and team_id != team:
        raise SetupError("The iOS team ID does not match the Apple Distribution certificate.")
    profile_plist = run_command(
        ["openssl", "cms", "-verify", "-noverify", "-inform", "DER", "-binary", "-in", "/dev/stdin"],
        provisioning_profile, label="iOS provisioning profile CMS signature")
    try:
        profile = plistlib.loads(profile_plist)
    except (ValueError, TypeError, plistlib.InvalidFileException):
        raise SetupError("The iOS provisioning profile does not contain a valid property list.") from None
    if not isinstance(profile, dict):
        raise SetupError("The iOS provisioning profile must contain a property list dictionary.")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise SetupError("The iOS provisioning profile has no valid entitlements.")
    if (profile.get("TeamIdentifier") != [team]
            or entitlements.get("com.apple.developer.team-identifier") != team):
        raise SetupError("The iOS provisioning profile and distribution certificate must belong to the same Apple team.")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    app_id = entitlements.get("application-identifier")
    if (not isinstance(prefixes, list) or not prefixes
            or not all(isinstance(prefix, str) and re.fullmatch(r"[A-Z0-9]{10}", prefix) for prefix in prefixes)
            or not isinstance(app_id, str)
            or app_id not in {f"{prefix}.{bundle_id}" for prefix in prefixes}):
        raise SetupError("The iOS provisioning profile must match the exact iOS bundle ID.")
    platform = profile.get("Platform")
    if (not isinstance(platform, list) or "iOS" not in platform
            or "ProvisionedDevices" in profile
            or profile.get("ProvisionsAllDevices", False) is not False
            or entitlements.get("get-task-allow") is not False
            or entitlements.get("beta-reports-active") is not True):
        raise SetupError("Use an iOS App Store distribution provisioning profile for TestFlight, not development, ad hoc, or enterprise.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        raise SetupError("The iOS provisioning profile has no valid expiration date.")
    if expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise SetupError("The iOS provisioning profile has expired. Generate a new App Store profile.")
    creation = profile.get("CreationDate")
    if isinstance(creation, datetime) and creation.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc):
        raise SetupError("The iOS provisioning profile is not yet valid.")
    certificate_der = run_command(["openssl", "x509", "-outform", "DER"], certificate,
                                  label="Apple Distribution certificate")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or certificate_der not in certificates:
        raise SetupError("The iOS provisioning profile does not include this Apple Distribution certificate.")
    try:
        profile_uuid = str(uuid.UUID(profile.get("UUID", ""))).upper()
    except (ValueError, AttributeError, TypeError):
        raise SetupError("The iOS provisioning profile has no valid UUID.") from None
    profile_name = profile.get("Name")
    if not isinstance(profile_name, str) or not profile_name.strip() or any(c in profile_name for c in "\r\n\0"):
        raise SetupError("The iOS provisioning profile has no valid name.")
    return {"team_id": team, "bundle_id": bundle_id, "profile_uuid": profile_uuid,
            "profile_name": profile_name, "key_id": key_id, "issuer_id": issuer}


def build_macos_secrets(args):
    application = read_credential(args.application_p12, "Application .p12")
    installer = read_credential(args.installer_p12, "Installer .p12")
    notary = read_credential(args.notary_key, "App Store Connect .p8")
    issuer = validate_api_key(notary, args.key_id, args.issuer_id)
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


def build_ios_secrets(args):
    distribution = read_credential(args.ios_distribution_p12, "Apple Distribution .p12")
    password = password_for(args.ios_distribution_password_file, "Apple Distribution")
    profile = read_credential(args.ios_provisioning_profile, "iOS App Store provisioning profile")
    api_key = read_credential(args.ios_api_key, "iOS App Store Connect .p8")
    metadata = validate_ios_material(distribution, password, profile, api_key,
                                     args.ios_key_id, args.ios_issuer_id, args.ios_bundle_id)
    return {
        "IOS_DISTRIBUTION_CERTIFICATE_BASE64": base64.b64encode(distribution),
        "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD": password,
        "IOS_PROVISIONING_PROFILE_BASE64": base64.b64encode(profile),
        "IOS_APP_STORE_CONNECT_KEY_BASE64": base64.b64encode(api_key),
        "IOS_APP_STORE_CONNECT_KEY_ID": metadata["key_id"].encode("ascii"),
        "IOS_APP_STORE_CONNECT_ISSUER_ID": metadata["issuer_id"].encode("ascii"),
        "IOS_TEAM_ID": metadata["team_id"].encode("ascii"),
        "IOS_BUNDLE_ID": metadata["bundle_id"].encode("ascii"),
    }


def build_secrets(args):
    secrets = {}
    platform = getattr(args, "platform", "macos")
    if platform in ("macos", "all"):
        secrets.update(build_macos_secrets(args))
    if platform in ("ios", "all"):
        secrets.update(build_ios_secrets(args))
    return secrets


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
    parser.add_argument("--platform", choices=("macos", "ios", "all"), default="macos", help="Release credentials to configure")
    parser.add_argument("--application-p12", help="Dedicated Dieter Developer ID Application certificate and private key export")
    parser.add_argument("--installer-p12", help="Dedicated Dieter Developer ID Installer certificate and private key export")
    parser.add_argument("--notary-key", help="Dedicated Dieter App Store Connect team API private key (.p8)")
    parser.add_argument("--key-id", help="App Store Connect API Key ID")
    parser.add_argument("--issuer-id", help="App Store Connect team API Issuer ID")
    parser.add_argument("--application-password-file", help="Private file containing the Application export password; otherwise prompt securely")
    parser.add_argument("--installer-password-file", help="Private file containing the Installer export password; otherwise prompt securely")
    parser.add_argument("--ios-distribution-p12", help="Dedicated Dieter Apple Distribution certificate and private key export")
    parser.add_argument("--ios-distribution-password-file", help="Private file containing the iOS distribution export password; otherwise prompt securely")
    parser.add_argument("--ios-provisioning-profile", help="Dedicated Dieter iOS App Store distribution provisioning profile (.mobileprovision)")
    parser.add_argument("--ios-api-key", help="Dedicated Dieter iOS App Store Connect team API private key (.p8)")
    parser.add_argument("--ios-key-id", help="iOS App Store Connect API Key ID")
    parser.add_argument("--ios-issuer-id", help="iOS App Store Connect team API Issuer ID")
    parser.add_argument("--ios-bundle-id", default="com.dbpprt.dieter.ios", help="Explicit registered iOS bundle ID")
    parser.add_argument("--check", action="store_true", help="Validate local inputs only; do not contact GitHub or upload secrets")
    args = parser.parse_args(argv)
    required = []
    if args.platform in ("macos", "all"):
        required += ["application_p12", "installer_p12", "notary_key", "key_id", "issuer_id"]
    if args.platform in ("ios", "all"):
        required += ["ios_distribution_p12", "ios_provisioning_profile", "ios_api_key", "ios_key_id", "ios_issuer_id"]
    missing = ["--" + name.replace("_", "-") for name in required if not getattr(args, name)]
    if missing:
        parser.error("the following arguments are required for this platform: " + ", ".join(missing))
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
