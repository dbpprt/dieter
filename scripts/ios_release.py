#!/usr/bin/env python3
"""Archive Dieter for iOS, or explicitly export/upload TestFlight builds in CI.

Signing uses only explicitly supplied iOS credentials and a temporary keychain.
Only bounded, redacted Xcode error summaries are printed; signing commands and
their raw output remain private.
"""

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

import configure_apple_signing as signing


ROOT = Path(__file__).resolve().parents[1]
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
    if any(not env.get(name) for name in SECRET_NAMES):
        raise ReleaseError("Complete dedicated iOS signing credentials are required; configure all IOS_* release inputs.")
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
        env["IOS_BUNDLE_ID"], team_id=env["IOS_TEAM_ID"], required_app_group=app_group)
    share_metadata = signing.validate_ios_material(
        certificate, password, share_profile, key,
        env["IOS_APP_STORE_CONNECT_KEY_ID"], env["IOS_APP_STORE_CONNECT_ISSUER_ID"],
        env["IOS_BUNDLE_ID"] + ".share", team_id=env["IOS_TEAM_ID"], required_app_group=app_group)
    return Material(certificate, password, profile, share_profile, key, metadata, share_metadata)


def signing_config(env):
    load_material(env)
    if env.get("GITHUB_OUTPUT"):
        try:
            with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
                stream.write("enabled=true\n")
        except OSError:
            raise ReleaseError("Could not write the validated signing configuration output.") from None
    print("Dedicated iOS signing configuration is valid.")


def release_parameters(version, build, bundle_id):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", version) or len(version) > 32:
        raise ReleaseError("Version must contain exactly three numeric components, such as 1.2.0.")
    if not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}", build):
        raise ReleaseError("Build must use one to three numeric components (major[.minor[.patch]]), with a positive major and 4/2/2 digit limits.")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id) or len(bundle_id) > 255:
        raise ReleaseError("The iOS bundle ID must be an explicit reverse-DNS identifier.")


def release_directory(root, version, build):
    output = root / "apps/ios/.build/release" / f"{version}-{build}"
    if os.path.lexists(output):
        raise ReleaseError("This version/build output already exists. Use a new build number or move the previous output.")
    return output


def write_private(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)


def replace_profile(path, content, mode=0o600):
    descriptor, name = tempfile.mkstemp(prefix=".dieter-profile-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def owned_identity(keychain):
    output = command(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        label="Temporary iOS signing identity lookup", timeout=30)
    identities = re.findall(rb'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"Apple Distribution:[^\r\n]*"\s*$',
                            output, re.MULTILINE)
    if len(identities) != 1:
        raise ReleaseError("The temporary keychain must contain exactly one valid Apple Distribution identity.")
    return identities[0].decode("ascii").upper()


@contextmanager
def signing_environment(material, runner_temp, *, home=None):
    home = Path.home() if home is None else home
    profile_directory = home / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profile_inputs = (
        (material.metadata["profile_uuid"], material.profile),
        (material.share_metadata["profile_uuid"], material.share_profile),
    )
    if profile_inputs[0][0] == profile_inputs[1][0]:
        raise ReleaseError("The app and Share extension provisioning profiles must have distinct UUIDs.")
    profiles = []
    for profile_uuid, content in profile_inputs:
        path = profile_directory / (profile_uuid + ".mobileprovision")
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise ReleaseError("A destination provisioning profile is not a regular file.")
        profiles.append({
            "path": path, "content": content,
            "previous": path.read_bytes() if path.exists() else None,
            "mode": stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600,
            "attempted": False,
        })
    try:
        previous_keychains = shlex.split(command(
            ["security", "list-keychains", "-d", "user"], label="Keychain search list read", timeout=30
        ).decode("utf-8"))
    except (ValueError, UnicodeError):
        raise ReleaseError("Could not read the current keychain search list.") from None
    private = Path(tempfile.mkdtemp(prefix="dieter-ios-signing-", dir=runner_temp))
    keychain = private / "release.keychain-db"
    keychain_attempted = False
    cleanup_errors = []
    try:
        certificate = private / "distribution.p12"
        key = private / ("AuthKey_" + material.metadata["key_id"] + ".p8")
        write_private(certificate, material.certificate)
        write_private(key, material.key)
        password = secrets.token_urlsafe(32)
        keychain_attempted = True
        command(["security", "create-keychain", "-p", password, keychain],
                label="Temporary keychain creation", timeout=30)
        command(["security", "set-keychain-settings", "-lut", "21600", keychain],
                label="Temporary keychain settings", timeout=30)
        command(["security", "unlock-keychain", "-p", password, keychain],
                label="Temporary keychain unlock", timeout=30)
        command(["security", "import", certificate, "-k", keychain, "-P", material.password.decode("utf-8"),
                 "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"],
                label="Dedicated iOS certificate import", timeout=30)
        command(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                 "-k", password, keychain], label="Temporary signing key access", timeout=30)
        identity = owned_identity(keychain)
        command(["security", "list-keychains", "-d", "user", "-s", keychain],
                label="Temporary keychain search list", timeout=30)
        profile_directory.mkdir(parents=True, exist_ok=True)
        for profile in profiles:
            profile["attempted"] = True
            replace_profile(profile["path"], profile["content"])
        yield {"directory": private, "key": key, "identity": identity, "password": password}
    finally:
        for profile in reversed(profiles):
            if not profile["attempted"]:
                continue
            try:
                if profile["previous"] is None:
                    profile["path"].unlink(missing_ok=True)
                else:
                    replace_profile(profile["path"], profile["previous"], profile["mode"])
            except OSError:
                cleanup_errors.append("profile")
        if keychain_attempted:
            try:
                command(["security", "delete-keychain", keychain], label="Temporary keychain deletion", timeout=30)
            except ReleaseError:
                # A failed creation may never have produced a keychain; the
                # private directory is still removed below and the list reset.
                if keychain.exists():
                    cleanup_errors.append("keychain")
            try:
                command(["security", "list-keychains", "-d", "user", "-s", *previous_keychains],
                        label="Original keychain search list restoration", timeout=30)
            except ReleaseError:
                cleanup_errors.append("search list")
        try:
            shutil.rmtree(private)
        except OSError:
            cleanup_errors.append("private files")
        if cleanup_errors:
            raise ReleaseError("Could not completely restore the temporary signing environment; inspect the CI runner before reuse.")


def archive_command(root, archive, version, build, bundle_id):
    return [
        "xcodebuild", "-project", root / "apps/ios/DieterIOS.xcodeproj", "-scheme", "DieterIOS",
        "-configuration", "Release", "-destination", "generic/platform=iOS",
        "-derivedDataPath", root / "apps/ios/.build/DerivedData", "-archivePath", archive,
        "archive", f"MARKETING_VERSION={version}", f"CURRENT_PROJECT_VERSION={build}",
        f"DIETER_IOS_BUNDLE_ID={bundle_id}",
    ]


def validate_info(info, version, build, bundle_id, *, require_camera_usage=True):
    if not isinstance(info, dict) or any(info.get(key) != value for key, value in (
        ("CFBundleIdentifier", bundle_id), ("CFBundleShortVersionString", version),
        ("CFBundleVersion", build),
    )):
        raise ReleaseError("The built app's bundle ID, version, or build number does not match the requested release.")
    if require_camera_usage and info.get("NSCameraUsageDescription") != CAMERA_USAGE_DESCRIPTION:
        raise ReleaseError("The built app is missing its camera usage description.")


def validate_archive(archive, version, build, bundle_id, *, signed):
    app = archive / "Products/Applications/Dieter.app"
    try:
        info = plistlib.loads((app / "Info.plist").read_bytes())
        archive_info = plistlib.loads((archive / "Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise ReleaseError("The iOS archive is missing valid application metadata.") from None
    validate_info(info, version, build, bundle_id)
    properties = archive_info.get("ApplicationProperties", {}) if isinstance(archive_info, dict) else {}
    validate_info(properties, version, build, bundle_id, require_camera_usage=False)
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


def export_options(metadata, identity, destination, share_metadata=None):
    profiles = {metadata["bundle_id"]: metadata["profile_uuid"]}
    if share_metadata is not None:
        profiles[share_metadata["bundle_id"]] = share_metadata["profile_uuid"]
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


def archive_unsigned(root, version, build, env):
    bundle_id = env.get("IOS_BUNDLE_ID", DEFAULT_BUNDLE_ID)
    release_parameters(version, build, bundle_id)
    output = release_directory(root, version, build)
    output.mkdir(parents=True)
    archive = output / "Dieter.xcarchive"
    command(archive_command(root, archive, version, build, bundle_id) + ["CODE_SIGNING_ALLOWED=NO"],
            label="Unsigned iOS archive", diagnostic_secrets=())
    validate_archive(archive, version, build, bundle_id, signed=False)
    print(f"Unsigned iOS archive: {archive}")
    return archive


def testflight(root, version, build, env, *, upload=False):
    if env.get("GITHUB_ACTIONS") != "true" or not env.get("RUNNER_TEMP"):
        raise ReleaseError("TestFlight signing is restricted to GitHub Actions with RUNNER_TEMP configured.")
    runner_temp = Path(env["RUNNER_TEMP"])
    if not runner_temp.is_absolute() or not runner_temp.is_dir():
        raise ReleaseError("RUNNER_TEMP must name an existing absolute runner temporary directory.")
    release_parameters(version, build, env.get("IOS_BUNDLE_ID", ""))
    output = release_directory(root, version, build)
    material = load_material(env)
    metadata = material.metadata
    with signing_environment(material, runner_temp) as context:
        diagnostic_secrets = (
            material.certificate, material.password, material.profile, material.share_profile, material.key,
            context["directory"], context["key"], context["identity"], context["password"],
            *(value for name, value in env.items() if name.startswith("IOS_")),
        )
        output.mkdir(parents=True)
        archive = output / "Dieter.xcarchive"
        command(archive_command(root, archive, version, build, metadata["bundle_id"]) + [
            f"DIETER_IOS_TEAM_ID={metadata['team_id']}", "DIETER_IOS_SIGN_STYLE=Manual",
            f"DIETER_IOS_SIGN_IDENTITY={context['identity']}",
            f"DIETER_IOS_PROFILE_SPECIFIER={metadata['profile_uuid']}",
            f"DIETER_IOS_SHARE_PROFILE_SPECIFIER={material.share_metadata['profile_uuid']}",
        ], label="Signed iOS archive", diagnostic_secrets=diagnostic_secrets)
        validate_archive(archive, version, build, metadata["bundle_id"], signed=True)
        options = context["directory"] / "ExportOptions.plist"
        write_private(
            options,
            plistlib.dumps(export_options(metadata, context["identity"], "export", material.share_metadata)))
        export = output / "Export"
        command(["xcodebuild", "-exportArchive", "-archivePath", archive,
                 "-exportPath", export, "-exportOptionsPlist", options], label="App Store IPA export",
                diagnostic_secrets=diagnostic_secrets)
        ipa = validate_ipa(export, version, build, metadata["bundle_id"])
        if upload:
            upload_options = context["directory"] / "UploadOptions.plist"
            write_private(
                upload_options,
                plistlib.dumps(export_options(metadata, context["identity"], "upload", material.share_metadata)))
            command(["xcodebuild", "-exportArchive", "-archivePath", archive,
                     "-exportPath", context["directory"] / "Upload", "-exportOptionsPlist", upload_options,
                     "-allowProvisioningUpdates", "-authenticationKeyPath", context["key"],
                     "-authenticationKeyID", metadata["key_id"], "-authenticationKeyIssuerID", metadata["issuer_id"]],
                    label="App Store Connect upload", diagnostic_secrets=diagnostic_secrets)
    print(f"Validated App Store IPA: {ipa}")
    if upload:
        print("Uploaded to App Store Connect for processing. Availability to TestFlight testers is not yet confirmed.")
    else:
        print("IPA exported locally; no upload was requested.")
    return ipa


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("signing-config", help="Require and validate all dedicated iOS release inputs")
    for name, help_text in (
        ("archive-unsigned", "Create an unsigned local device archive"),
        ("testflight", "Archive and export with dedicated signing credentials in GitHub Actions"),
    ):
        subparser = subparsers.add_parser(name, help=help_text)
        subparser.add_argument("version")
        subparser.add_argument("build")
        if name == "testflight":
            subparser.add_argument("--upload", action="store_true", help="Explicitly upload the validated IPA for App Store Connect processing")
    args = parser.parse_args(argv)
    try:
        if args.command == "signing-config":
            signing_config(os.environ)
        elif args.command == "archive-unsigned":
            archive_unsigned(ROOT, args.version, args.build, os.environ)
        else:
            testflight(ROOT, args.version, args.build, os.environ, upload=args.upload)
    except (ReleaseError, signing.SetupError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, UnicodeError):
        print("error: The iOS release operation could not complete safely. Check input files and runner permissions.", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: iOS release canceled.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
