"""Release safety contracts using disposable files and mocked Apple commands."""

import base64
import contextlib
import io
import os
from pathlib import Path
import plistlib
import shlex
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from fastlane.lib.dieter.native import ios_metadata as release


META = {
    "team_id": "ABCDEFGHIJ", "bundle_id": "com.dbpprt.dieter.ios",
    "profile_uuid": "01234567-89AB-CDEF-0123-456789ABCDEF", "profile_name": "Dedicated Dieter App Store",
    "key_id": "KLMNOPQRST", "issuer_id": "89abcdef-0123-4567-89ab-cdef01234567",
}
SHARE_META = {
    **META,
    "bundle_id": META["bundle_id"] + ".share",
    "profile_uuid": "FEDCBA98-7654-3210-FEDC-BA9876543210",
    "profile_name": "Dedicated Dieter Share App Store",
}
IDENTITY = "A" * 40
CERTIFICATE = b"dedicated certificate fixture"
PASSWORD = b"private p12 password fixture"
PROFILE = b"dedicated profile fixture"
SHARE_PROFILE = b"dedicated share profile fixture"
KEY = b"private API key fixture"


def fixture_env(runner_temp):
    return {
        "GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(runner_temp),
        "IOS_DISTRIBUTION_CERTIFICATE_BASE64": base64.b64encode(CERTIFICATE).decode(),
        "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD": PASSWORD.decode(),
        "IOS_PROVISIONING_PROFILE_BASE64": base64.b64encode(PROFILE).decode(),
        "IOS_SHARE_PROVISIONING_PROFILE_BASE64": base64.b64encode(SHARE_PROFILE).decode(),
        "IOS_APP_STORE_CONNECT_KEY_BASE64": base64.b64encode(KEY).decode(),
        "IOS_APP_STORE_CONNECT_KEY_ID": META["key_id"],
        "IOS_APP_STORE_CONNECT_ISSUER_ID": META["issuer_id"],
        "IOS_TEAM_ID": META["team_id"], "IOS_BUNDLE_ID": META["bundle_id"],
    }


def create_archive(path, version="1.2.3", build="42", bundle_id=META["bundle_id"]):
    app = path / "Products/Applications/Dieter.app"
    framework = app / "Frameworks/DieterIOS.framework"
    framework.mkdir(parents=True)
    (framework / "DieterIOS").write_bytes(b"framework fixture")
    (app / "Dieter").write_bytes(b"app fixture")
    share = app / "PlugIns/DieterShare.appex"
    share.mkdir(parents=True)
    (share / "DieterShare").write_bytes(b"share fixture")
    (share / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id + ".share", "CFBundleExecutable": "DieterShare",
    }))
    info = {"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version,
            "CFBundleVersion": build, "CFBundleExecutable": "Dieter",
            "DieterReleaseVersion": version,
            "NSCameraUsageDescription": release.CAMERA_USAGE_DESCRIPTION,
            "ITSAppUsesNonExemptEncryption": False}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    (path / "Info.plist").write_bytes(plistlib.dumps({
        "ApplicationProperties": {
            "CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version,
            "CFBundleVersion": build, "ApplicationPath": "Applications/Dieter.app",
        }
    }))


class FakeCommands:
    """Simulates only task-owned artifacts and the runner keychain search list."""

    def __init__(self, testcase, *, fail_label=None):
        self.testcase = testcase
        self.fail_label = fail_label
        self.calls = []
        self.export_options = []
        self.original_search_list = ["/runner/Library/Keychains/login.keychain-db", "/runner/extra keychain.keychain-db"]
        self.search_list = list(self.original_search_list)
        self.keychain = None
        self.uploads = 0

    def __call__(self, argv, *, label, **kwargs):
        argv = [str(value) for value in argv]
        self.calls.append((argv, label))
        if label == self.fail_label:
            raise release.ReleaseError("Simulated release step failed.")
        if argv[:4] == ["security", "list-keychains", "-d", "user"]:
            if "-s" in argv:
                self.search_list = argv[5:]
                return b""
            return ("\n".join(shlex.quote(value) for value in self.search_list)).encode()
        if argv[:2] == ["security", "create-keychain"]:
            self.keychain = Path(argv[-1])
            self.keychain.write_bytes(b"owned keychain fixture")
            self.search_list.append(str(self.keychain))
        elif argv[:2] == ["security", "delete-keychain"]:
            Path(argv[-1]).unlink(missing_ok=True)
            self.search_list = [value for value in self.search_list if value != argv[-1]]
        elif argv[:2] == ["security", "find-identity"]:
            self.testcase.assertEqual(Path(argv[-1]), self.keychain)
            return f'  1) {IDENTITY} "Apple Distribution: Dieter (ABCDEFGHIJ)"\n  1 valid identities found\n'.encode()
        elif argv[:2] == ["security", "import"]:
            certificate = Path(argv[2])
            self.testcase.assertEqual(certificate.read_bytes(), CERTIFICATE)
            self.testcase.assertEqual(stat.S_IMODE(certificate.stat().st_mode), 0o600)
            self.testcase.assertEqual(stat.S_IMODE(certificate.parent.stat().st_mode), 0o700)
        elif argv[0] == "xcodebuild" and "archive" in argv:
            archive = Path(argv[argv.index("-archivePath") + 1])
            settings = dict(value.split("=", 1) for value in argv if "=" in value)
            create_archive(archive, settings["MARKETING_VERSION"], settings["CURRENT_PROJECT_VERSION"],
                           settings["DIETER_IOS_BUNDLE_ID"])
        elif argv[:2] == ["xcodebuild", "-exportArchive"]:
            options = plistlib.loads(Path(argv[argv.index("-exportOptionsPlist") + 1]).read_bytes())
            self.export_options.append(options)
            if options["destination"] == "upload":
                self.uploads += 1
                key = Path(argv[argv.index("-authenticationKeyPath") + 1])
                self.testcase.assertEqual(key.read_bytes(), KEY)
                self.testcase.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
            else:
                directory = Path(argv[argv.index("-exportPath") + 1])
                directory.mkdir(parents=True)
                archive = Path(argv[argv.index("-archivePath") + 1])
                app = archive / "Products/Applications/Dieter.app"
                with zipfile.ZipFile(directory / "Dieter.ipa", "w") as ipa:
                    ipa.writestr("Payload/Dieter.app/Info.plist", (app / "Info.plist").read_bytes())
                    ipa.writestr("Payload/Dieter.app/Frameworks/DieterIOS.framework/DieterIOS", b"framework fixture")
                    ipa.writestr("Payload/Dieter.app/PlugIns/DieterShare.appex/DieterShare", b"share fixture")
        return b""


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runner = self.root / "runner-temp"
        self.runner.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = fixture_env(self.runner)
        self.profile = self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles" / (
            META["profile_uuid"] + ".mobileprovision")
        self.share_profile = self.home / "Library/Developer/Xcode/UserData/Provisioning Profiles" / (
            SHARE_META["profile_uuid"] + ".mobileprovision")

    def material(self):
        return release.Material(
            CERTIFICATE, PASSWORD, PROFILE, SHARE_PROFILE, KEY, dict(META), dict(SHARE_META))

    def validate_material(self, *args, **kwargs):
        return dict(SHARE_META if args[6].endswith(".share") else META)

    def run_signed(self, commands, *, upload=False, build="42", env=None):
        with patch.object(release.signing, "validate_ios_material", side_effect=self.validate_material), \
                patch.object(release, "command", side_effect=commands), \
                patch.object(Path, "home", return_value=self.home), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            result = release.testflight(
                self.root, "1.2.3", build, self.env if env is None else env, upload=upload)
        return result, output.getvalue()

    def assert_clean(self, commands):
        self.assertEqual(commands.search_list, commands.original_search_list)
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_material_validator_receives_all_original_bytes_and_expected_team(self):
        with patch.object(
            release.signing, "validate_ios_material", side_effect=self.validate_material
        ) as validate:
            material = release.load_material(self.env)
        self.assertEqual(validate.call_count, 2)
        validate.assert_any_call(
            CERTIFICATE, PASSWORD, PROFILE, KEY, META["key_id"], META["issuer_id"], META["bundle_id"],
            team_id=META["team_id"], required_app_group="group." + META["bundle_id"])
        validate.assert_any_call(
            CERTIFICATE, PASSWORD, SHARE_PROFILE, KEY, META["key_id"], META["issuer_id"],
            META["bundle_id"] + ".share", team_id=META["team_id"],
            required_app_group="group." + META["bundle_id"])
        self.assertEqual(material.metadata, META)
        self.assertEqual(material.share_metadata, SHARE_META)
        self.assertNotIn(PASSWORD.decode(), repr(material))

    def test_missing_configuration_fails_closed_without_output_or_validation(self):
        output = self.root / "github-output"
        for missing in [None, *release.SECRET_NAMES]:
            with self.subTest(missing=missing):
                env = dict(self.env) if missing else {}
                if missing:
                    del env[missing]
                env["GITHUB_OUTPUT"] = str(output)
                with patch.object(release.signing, "validate_ios_material") as validate, \
                        self.assertRaisesRegex(release.ReleaseError, "Complete dedicated"):
                    release.load_material(env)
                validate.assert_not_called()
                self.assertFalse(output.exists())


    def test_missing_share_profile_fails_before_signing(self):
        env = dict(self.env)
        del env["IOS_SHARE_PROVISIONING_PROFILE_BASE64"]
        with patch.object(release, "command") as command, \
                patch.object(release.signing, "validate_ios_material") as validate, \
                self.assertRaisesRegex(
                    release.ReleaseError, "IOS_SHARE_PROVISIONING_PROFILE_BASE64"):
            release.load_material(env)
        command.assert_not_called()
        validate.assert_not_called()

    def test_invalid_share_profile_fails_before_signing(self):
        with patch.object(release, "command") as command, \
                patch.object(release.signing, "validate_ios_material") as validate, \
                self.assertRaises(release.ReleaseError):
            release.load_material(dict(self.env, IOS_SHARE_PROVISIONING_PROFILE_BASE64="%notbase64"))
        command.assert_not_called()
        validate.assert_not_called()
















    def test_archive_mismatch_missing_binary_framework_and_share_extension_block_export(self):
        for defect in ("version", "release", "build", "bundle", "camera", "encryption", "executable", "framework", "share", "archive"):
            with self.subTest(defect=defect):
                archive = self.root / defect / "Dieter.xcarchive"
                create_archive(archive)
                app = archive / "Products/Applications/Dieter.app"
                if defect in ("version", "release", "build", "bundle", "camera", "encryption"):
                    info = plistlib.loads((app / "Info.plist").read_bytes())
                    key = {"version": "CFBundleShortVersionString", "release": "DieterReleaseVersion", "build": "CFBundleVersion",
                           "bundle": "CFBundleIdentifier", "camera": "NSCameraUsageDescription",
                           "encryption": "ITSAppUsesNonExemptEncryption"}[defect]
                    info[key] = "wrong"
                    (app / "Info.plist").write_bytes(plistlib.dumps(info))
                elif defect == "executable":
                    (app / "Dieter").unlink()
                elif defect == "framework":
                    (app / "Frameworks/DieterIOS.framework/DieterIOS").unlink()
                elif defect == "share":
                    (app / "PlugIns/DieterShare.appex/DieterShare").unlink()
                else:
                    (archive / "Info.plist").write_bytes(b"invalid plist")
                with patch.object(release, "command") as command, self.assertRaises(release.ReleaseError):
                    release.validate_archive(archive, "1.2.3", "42", META["bundle_id"], signed=True)
                command.assert_not_called()


    def test_ipa_validation_checks_count_metadata_framework_and_share_extension(self):
        for defect in ("missing", "extra", "invalid-zip", "metadata", "release", "encryption", "framework", "share"):
            with self.subTest(defect=defect):
                directory = self.root / ("ipa-" + defect)
                directory.mkdir()
                if defect == "invalid-zip":
                    (directory / "Dieter.ipa").write_bytes(b"invalid zip")
                elif defect != "missing":
                    with zipfile.ZipFile(directory / "Dieter.ipa", "w") as ipa:
                        info = {"CFBundleIdentifier": META["bundle_id"], "CFBundleShortVersionString": "1.2.3",
                                "CFBundleVersion": "wrong" if defect == "metadata" else "42",
                                "DieterReleaseVersion": "wrong" if defect == "release" else "1.2.3",
                                "NSCameraUsageDescription": release.CAMERA_USAGE_DESCRIPTION,
                                "ITSAppUsesNonExemptEncryption": defect == "encryption"}
                        ipa.writestr("Payload/Dieter.app/Info.plist", plistlib.dumps(info))
                        if defect != "framework":
                            ipa.writestr("Payload/Dieter.app/Frameworks/DieterIOS.framework/DieterIOS", b"framework")
                        if defect != "share":
                            ipa.writestr("Payload/Dieter.app/PlugIns/DieterShare.appex/DieterShare", b"share")
                    if defect == "extra":
                        (directory / "Extra.ipa").write_bytes(b"another zip")
                with self.assertRaises(release.ReleaseError):
                    release.validate_ipa(directory, "1.2.3", "42", META["bundle_id"])



    def test_xcode_failures_report_actionable_errors_without_raw_output(self):
        result = subprocess.CompletedProcess([], 65, stdout=b"Command line invocation:\nprivate compiler argv\n",
                                             stderr=b'project: error: Provisioning profile does not support target DieterIOSApp.\n')
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as caught:
                release.command(["xcodebuild", "archive"], label="Signed iOS archive", diagnostic_secrets=())
        self.assertIn("Provisioning profile does not support target DieterIOSApp", str(caught.exception))
        self.assertNotIn("private compiler argv", str(caught.exception))
        self.assertNotIn("Command line invocation", str(caught.exception))

    def test_xcode_errors_redact_encoded_decoded_and_runtime_signing_values(self):
        pem = b"-----BEGIN PRIVATE KEY-----\nSYNTHETIC_PRIVATE_KEY_BASE64_LINE\n-----END PRIVATE KEY-----\n"
        env = dict(self.env, IOS_APP_STORE_CONNECT_KEY_BASE64=base64.b64encode(pem).decode())
        runtime = "/private/dieter-ios-signing-owned"
        values = [*env.values(), CERTIFICATE.decode(), PROFILE.decode(), PASSWORD.decode(),
                  "SYNTHETIC_PRIVATE_KEY_BASE64_LINE", runtime, "generated keychain password"]
        errors = "\n".join("error: Invalid signing input " + value for value in values).encode()
        result = subprocess.CompletedProcess([], 65, stdout=b"", stderr=errors)
        with patch.dict(os.environ, env), patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as caught:
                release.command(["xcodebuild", "-exportArchive"], label="App Store IPA export",
                                diagnostic_secrets=(runtime, "generated keychain password"))
        message = str(caught.exception)
        self.assertIn("Invalid signing input", message)
        self.assertIn("[redacted]", message)
        for value in values:
            if value not in ("true", str(self.runner)):
                self.assertNotIn(value, message)

    def test_xcode_summary_is_bounded_and_ignores_echoed_commands_and_private_key_blocks(self):
        output = b"error: security import secret.p12 -P secret\nerror: -----BEGIN PRIVATE KEY-----\n"
        output += b"error: " + b"a" * 9000 + b"\n"
        output += b"\n".join(f"error: failure {index}: ".encode() + b"x" * 700 for index in range(20))
        summary = release.xcode_error_summary(output, b"", ())
        self.assertEqual(len(summary.splitlines()), 8)
        self.assertLessEqual(len(summary), 8 * 510)
        self.assertNotIn("security import", summary)
        self.assertNotIn("PRIVATE KEY", summary)

    def test_xcode_summary_omits_each_echoed_security_command_without_truncation(self):
        for echoed in ("security import secret.p12 -P private-password", "security -v import secret.p12",
                       "/usr/bin/security unlock-keychain -p private-password owned.keychain-db"):
            with self.subTest(command_form=echoed.split()[0]):
                self.assertEqual(release.xcode_error_summary(("error: " + echoed).encode(), b"", ()), "")

    def test_security_errors_remain_opaque_even_if_diagnostics_requested(self):
        result = subprocess.CompletedProcess([], 1, stdout=b"error: private keychain details", stderr=PASSWORD)
        with patch.object(release.subprocess, "run", return_value=result):
            with self.assertRaises(release.ReleaseError) as caught:
                release.command(["security", "import", "private.p12"], label="Certificate import", diagnostic_secrets=())
        self.assertIn("withheld", str(caught.exception))
        self.assertNotIn("private keychain details", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
