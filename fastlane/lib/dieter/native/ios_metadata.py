#!/usr/bin/env python3
"""Pure Apple credential and archive metadata validation used by the pipeline."""

import argparse
import base64
import binascii
from contextlib import contextmanager
from dataclasses import dataclass, field
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

from fastlane.lib.dieter.native import apple_credentials as signing


ROOT = Path(__file__).resolve().parents[4]
DEFAULT_BUNDLE_ID = "com.dbpprt.dieter.ios"
CAMERA_USAGE_DESCRIPTION = (
    "Dieter includes camera-capable WebRTC components for remote screen viewing. "
    "Dieter does not capture or transmit camera video."
)
SECRET_NAMES = (
    "IOS_DISTRIBUTION_CERTIFICATE_BASE64", "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD",
    "IOS_PROVISIONING_PROFILE_BASE64", "IOS_SHARE_PROVISIONING_PROFILE_BASE64",
    "IOS_APP_STORE_CONNECT_KEY_BASE64",
    "IOS_APP_STORE_CONNECT_KEY_ID", "IOS_APP_STORE_CONNECT_ISSUER_ID",
    "IOS_TEAM_ID", "IOS_BUNDLE_ID",
)


class ReleaseError(Exception):
    """An actionable message that never contains credential material."""


@dataclass(repr=False)
class Material:
    certificate: bytes = field(repr=False)
    password: bytes = field(repr=False)
    profile: bytes = field(repr=False)
    share_profile: bytes = field(repr=False)
    key: bytes = field(repr=False)
    metadata: dict
    share_metadata: dict


def xcode_error_summary(stdout, stderr, secrets_to_redact):
    """Select error messages only, redact before truncation, and never emit argv."""
    values = list(secrets_to_redact)
    for name, value in os.environ.items():
        if name.startswith("IOS_") and value:
            values.append(value)
            if name.endswith("_BASE64"):
                try:
                    values.append(base64.b64decode(value, validate=True))
                except (ValueError, binascii.Error):
                    pass
    redactions = set()
    for value in values:
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")
        else:
            value = str(value)
        if value:
            redactions.add(value)
            redactions.add(shlex.quote(value))
            # A PEM key may be echoed one base64 line at a time.
            if "-----BEGIN" in value:
                redactions.update(line for line in value.splitlines() if line and not line.startswith("-----"))
    messages = []
    for output in (stdout, stderr):
        # Only examine complete lines in a bounded tail of each output stream.
        tail = output[-256 * 1024:]
        if len(tail) < len(output):
            tail = tail.partition(b"\n")[2]
        for line in tail.decode("utf-8", errors="replace").splitlines():
            if len(line) > 8192 or "PRIVATE KEY" in line:
                continue
            match = re.search(r"\b(?:fatal )?error:\s*(.+)", line, re.IGNORECASE)
            if not match:
                continue
            message = match.group(1)
            if re.search(r"\b(?:xcodebuild|codesign)\s+-|\bsecurity\s+(?:-|[a-z][a-z-]*\b)", message, re.IGNORECASE):
                continue
            for value in sorted(redactions, key=len, reverse=True):
                message = message.replace(value, "[redacted]")
            # Remove terminal controls and avoid executable workflow directives.
            message = " ".join("".join(c for c in message if c.isprintable()).split())[:500]
            if message and message not in messages:
                messages.append(message)
    return "\n".join("  Xcode: " + message for message in messages[-8:])


def command(argv, *, label, timeout=3600, include_stderr=False, diagnostic_secrets=None):
    # Child tools receive private files only when needed, not every CI secret.
    env = {name: value for name, value in os.environ.items() if not name.startswith("IOS_")}
    try:
        result = subprocess.run(
            [str(value) for value in argv], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, timeout=timeout, cwd=ROOT, env=env)
    except (OSError, subprocess.TimeoutExpired):
        raise ReleaseError(f"{label} could not run or timed out.") from None
    if result.returncode:
        if (diagnostic_secrets is not None and Path(str(argv[0])).name == "xcodebuild"
                and ("archive" in argv or "-exportArchive" in argv)):
            summary = xcode_error_summary(result.stdout, result.stderr, diagnostic_secrets)
            if summary:
                raise ReleaseError(f"{label} failed. Redacted Xcode errors:\n{summary}")
        raise ReleaseError(f"{label} failed. Command output was withheld to protect signing credentials.")
    return result.stdout + result.stderr if include_stderr else result.stdout


def decoded_secret(env, name):
    value = env[name]
    if not value or len(value) > signing.MAX_SECRET_BYTES:
        raise ReleaseError(f"{name} is empty or exceeds the secret size limit.")
    try:
        result = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError, UnicodeError):
        raise ReleaseError(f"{name} is not valid base64.") from None
    if not result:
        raise ReleaseError(f"{name} contains no credential data.")
    if base64.b64encode(result).decode("ascii") != value:
        raise ReleaseError(f"{name} is not canonical base64.")
    return result


def load_material(env):
    missing = [name for name in SECRET_NAMES if not env.get(name)]
    if missing:
        raise ReleaseError(
            "Complete dedicated iOS signing credentials are required; missing: "
            + ", ".join(missing) + ".")
    certificate = decoded_secret(env, "IOS_DISTRIBUTION_CERTIFICATE_BASE64")
    profile = decoded_secret(env, "IOS_PROVISIONING_PROFILE_BASE64")
    share_profile = decoded_secret(env, "IOS_SHARE_PROVISIONING_PROFILE_BASE64")
    key = decoded_secret(env, "IOS_APP_STORE_CONNECT_KEY_BASE64")
    password = env["IOS_DISTRIBUTION_CERTIFICATE_PASSWORD"].encode("utf-8")
    if (not password or len(password) > signing.MAX_PASSWORD_BYTES
            or any(value in password for value in (b"\n", b"\r", b"\0"))):
        raise ReleaseError("The iOS certificate password must be a nonempty single line of at most 1024 bytes.")
    app_group = "group." + env["IOS_BUNDLE_ID"]
    metadata = signing.validate_ios_material(
        certificate, password, profile, key,
        env["IOS_APP_STORE_CONNECT_KEY_ID"], env["IOS_APP_STORE_CONNECT_ISSUER_ID"],
        env["IOS_BUNDLE_ID"], team_id=env["IOS_TEAM_ID"],
        required_app_group=app_group)
    share_metadata = signing.validate_ios_material(
        certificate, password, share_profile, key,
        env["IOS_APP_STORE_CONNECT_KEY_ID"], env["IOS_APP_STORE_CONNECT_ISSUER_ID"],
        env["IOS_BUNDLE_ID"] + ".share", team_id=env["IOS_TEAM_ID"],
        required_app_group=app_group)
    return Material(certificate, password, profile, share_profile, key, metadata, share_metadata)


def validate_info(info, version, build, bundle_id, *, require_app_declarations=True):
    if not isinstance(info, dict) or any(info.get(key) != value for key, value in (
        ("CFBundleIdentifier", bundle_id), ("CFBundleShortVersionString", version),
        ("CFBundleVersion", build),
    )):
        raise ReleaseError("The built app's bundle ID, version, or build number does not match the requested release.")
    if require_app_declarations and info.get("DieterReleaseVersion") != version:
        raise ReleaseError("The built app's Dieter release version does not match the requested release.")
    if require_app_declarations and info.get("NSCameraUsageDescription") != CAMERA_USAGE_DESCRIPTION:
        raise ReleaseError("The built app is missing its camera usage description.")
    if require_app_declarations and info.get("ITSAppUsesNonExemptEncryption") is not False:
        raise ReleaseError("The built app must declare ITSAppUsesNonExemptEncryption as false.")


def validate_archive(archive, version, build, bundle_id, *, signed):
    app = archive / "Products/Applications/Dieter.app"
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
        archive_info = plistlib.loads((archive / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise ReleaseError("The iOS archive is missing valid application metadata.") from None
    validate_info(info, version, build, bundle_id)
    properties = archive_info.get("ApplicationProperties", {}) if isinstance(archive_info, dict) else {}
    validate_info(properties, version, build, bundle_id, require_app_declarations=False)
    if properties.get("ApplicationPath") != "Applications/Dieter.app":
        raise ReleaseError("The archive does not contain the expected Dieter iOS application.")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise ReleaseError("The archive is missing the Dieter executable.")
    framework = app / "Frameworks/DieterIOS.framework"
    if not framework.is_dir() or not (framework / "DieterIOS").is_file():
        raise ReleaseError("The archive is missing its embedded DieterIOS framework.")
    share = app / "PlugIns/DieterShare.appex"
    try:
        share_info = plistlib.loads((share / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise ReleaseError("The archive is missing its Share extension metadata.") from None
    share_executable = share_info.get("CFBundleExecutable")
    if (share_info.get("CFBundleIdentifier") != bundle_id + ".share"
            or not isinstance(share_executable, str) or not share_executable
            or Path(share_executable).name != share_executable
            or not (share / share_executable).is_file()):
        raise ReleaseError("The archive is missing its Share extension executable.")
    if signed:
        command(["codesign", "--verify", "--deep", "--strict", app], label="Archived iOS signature verification", timeout=120)


def export_options(metadata, identity, destination, share_metadata):
    profiles = {
        metadata["bundle_id"]: metadata["profile_uuid"],
        share_metadata["bundle_id"]: share_metadata["profile_uuid"],
    }
    return {
        "method": "app-store-connect", "destination": destination, "signingStyle": "manual",
        "teamID": metadata["team_id"], "signingCertificate": identity,
        "provisioningProfiles": profiles,
        "manageAppVersionAndBuildNumber": False, "uploadSymbols": True,
    }


def validate_ipa(directory, version, build, bundle_id):
    candidates = list(directory.glob("*.ipa"))
    if len(candidates) != 1:
        raise ReleaseError("Export must produce exactly one IPA.")
    try:
        with zipfile.ZipFile(candidates[0]) as ipa:
            info = plistlib.loads(ipa.read("Payload/Dieter.app/Info.plist"))
            validate_info(info, version, build, bundle_id)
            if "Payload/Dieter.app/Frameworks/DieterIOS.framework/DieterIOS" not in ipa.namelist():
                raise ReleaseError("The exported IPA is missing its embedded DieterIOS framework.")
            if "Payload/Dieter.app/PlugIns/DieterShare.appex/DieterShare" not in ipa.namelist():
                raise ReleaseError("The exported IPA is missing its Share extension.")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException):
        raise ReleaseError("The exported IPA does not contain a valid Dieter iOS app.") from None
    return candidates[0]
