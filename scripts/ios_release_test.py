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

import ios_release as release


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
            "NSCameraUsageDescription": release.CAMERA_USAGE_DESCRIPTION}
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
                    release.signing_config(env)
                validate.assert_not_called()
                self.assertFalse(output.exists())

    def test_signing_config_sets_output_only_after_validation(self):
        output = self.root / "github-output"
        env = dict(self.env, GITHUB_OUTPUT=str(output))
        with patch.object(release.signing, "validate_ios_material", side_effect=self.validate_material), \
                contextlib.redirect_stdout(io.StringIO()):
            release.signing_config(env)
        self.assertEqual(output.read_text(), "enabled=true\n")

    def test_missing_share_profile_selects_automatic_provisioning(self):
        env = dict(self.env)
        del env["IOS_SHARE_PROVISIONING_PROFILE_BASE64"]
        commands = FakeCommands(self)
        ipa, output = self.run_signed(commands, env=env)
        self.assertTrue(ipa.is_file())
        self.assertIn("no upload was requested", output)
        archive = next(argv for argv, _ in commands.calls if "archive" in argv)
        for value in (
            f"DIETER_IOS_TEAM_ID={META['team_id']}", "DIETER_IOS_SIGN_STYLE=Automatic",
            "DIETER_IOS_SIGN_IDENTITY=", "-allowProvisioningUpdates", "-authenticationKeyPath",
            "-authenticationKeyID", "-authenticationKeyIssuerID",
        ):
            self.assertIn(value, archive)
        self.assertFalse(any(value.startswith("DIETER_IOS_SHARE_PROFILE_SPECIFIER=") for value in archive))
        self.assertEqual(commands.export_options, [
            release.export_options(META, IDENTITY, "export", automatic=True),
        ])
        self.assertNotIn("signingCertificate", commands.export_options[0])
        self.assertNotIn("provisioningProfiles", commands.export_options[0])
        export = next(argv for argv, _ in commands.calls if "-exportArchive" in argv)
        self.assertIn("-allowProvisioningUpdates", export)
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.share_profile.exists())
        self.assert_clean(commands)

    def test_invalid_optional_share_profile_fails_before_signing(self):
        with patch.object(release, "command") as command, \
                patch.object(release.signing, "validate_ios_material") as validate, \
                self.assertRaises(release.ReleaseError):
            release.testflight(
                self.root, "1.2.3", "42",
                dict(self.env, IOS_SHARE_PROVISIONING_PROFILE_BASE64="%notbase64"))
        command.assert_not_called()
        validate.assert_not_called()

    def test_invalid_configuration_does_not_touch_keychain_profile_or_artifacts(self):
        for name in (value for value in release.SECRET_NAMES if value.endswith("_BASE64")):
            for invalid in ("%notbase64", "YQ====", "YW Jj", "á"):
                with self.subTest(name=name, invalid=invalid), \
                        patch.object(release, "command") as command, \
                        patch.object(release.signing, "validate_ios_material") as validate, \
                        self.assertRaises(release.ReleaseError):
                    release.testflight(self.root, "1.2.3", "42", dict(self.env, **{name: invalid}))
                command.assert_not_called()
                validate.assert_not_called()
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.share_profile.exists())
        self.assertFalse((self.root / "apps").exists())

    def test_material_mismatch_has_no_signing_side_effects(self):
        with patch.object(release.signing, "validate_ios_material", side_effect=release.signing.SetupError("Team mismatch.")), \
                patch.object(release, "command") as command, self.assertRaises(release.signing.SetupError):
            release.testflight(self.root, "1.2.3", "42", self.env)
        command.assert_not_called()
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_ci_gate_blocks_local_signing_and_upload(self):
        for env in ({}, dict(self.env, GITHUB_ACTIONS="false"), dict(self.env, RUNNER_TEMP="relative"),
                    dict(self.env, RUNNER_TEMP=str(self.root / "missing"))):
            with self.subTest(env_keys=list(env)), patch.object(release, "command") as command, \
                    patch.object(release, "load_material") as material, self.assertRaises(release.ReleaseError):
                release.testflight(self.root, "1.2.3", "42", env, upload=True)
            command.assert_not_called()
            material.assert_not_called()

    def test_invalid_versions_and_existing_output_do_not_build(self):
        for version, build in (("../1", "42"), ("1", "42"), ("1.2", "42"), ("1.2.3", "0"),
                               ("1.2.3", "../42"), ("1.2.3.4", "42")):
            with self.subTest(version=version, build=build), patch.object(release, "command") as command, \
                    self.assertRaises(release.ReleaseError):
                release.archive_unsigned(self.root, version, build, {})
            command.assert_not_called()
        destination = self.root / "apps/ios/.build/release/1.2.3-42"
        destination.mkdir(parents=True)
        with patch.object(release, "command") as command, self.assertRaisesRegex(release.ReleaseError, "already exists"):
            release.archive_unsigned(self.root, "1.2.3", "42", {})
        command.assert_not_called()

    def test_unsigned_archive_uses_canonical_cache_and_never_signs_or_uploads(self):
        commands = FakeCommands(self)
        with patch.object(release, "command", side_effect=commands), \
                patch.object(release, "load_material") as material, contextlib.redirect_stdout(io.StringIO()):
            result = release.archive_unsigned(self.root, "1.2.3", "42", {})
        material.assert_not_called()
        self.assertEqual(result, self.root / "apps/ios/.build/release/1.2.3-42/Dieter.xcarchive")
        self.assertEqual(len(commands.calls), 1)
        argv = commands.calls[0][0]
        self.assertIn("CODE_SIGNING_ALLOWED=NO", argv)
        self.assertEqual(argv[argv.index("-destination") + 1], "generic/platform=iOS")
        self.assertEqual(argv[argv.index("-derivedDataPath") + 1], str(self.root / "apps/ios/.build/DerivedData"))

    def test_signed_export_is_scoped_to_owned_identity_and_has_no_upload_by_default(self):
        commands = FakeCommands(self)
        ipa, output = self.run_signed(commands)
        self.assertTrue(ipa.is_file())
        self.assertEqual(commands.uploads, 0)
        self.assertIn("no upload was requested", output)
        self.assert_clean(commands)
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.share_profile.exists())
        archive = next(argv for argv, _ in commands.calls if "archive" in argv)
        for setting in (
            f"DIETER_IOS_TEAM_ID={META['team_id']}", "DIETER_IOS_SIGN_STYLE=Manual",
            f"DIETER_IOS_SIGN_IDENTITY={IDENTITY}", f"DIETER_IOS_PROFILE_SPECIFIER={META['profile_uuid']}",
            f"DIETER_IOS_SHARE_PROFILE_SPECIFIER={SHARE_META['profile_uuid']}",
        ):
            self.assertIn(setting, archive)
        self.assertFalse(any(value.startswith(("PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_IDENTITY=")) for value in archive))
        self.assertTrue(any(argv[:4] == ["codesign", "--verify", "--deep", "--strict"] for argv, _ in commands.calls))
        self.assertEqual(
            commands.export_options,
            [release.export_options(META, IDENTITY, "export", SHARE_META)])
        self.assertEqual(commands.export_options[0]["method"], "app-store-connect")
        self.assertFalse(commands.export_options[0]["manageAppVersionAndBuildNumber"])
        self.assertTrue(commands.export_options[0]["uploadSymbols"])
        for path in (self.root / "apps/ios/.build/release").rglob("*"):
            if path.is_file():
                self.assertNotIn(PASSWORD, path.read_bytes())
                self.assertNotIn(KEY, path.read_bytes())
                self.assertNotIn(CERTIFICATE, path.read_bytes())

    def test_upload_is_a_second_explicit_export_with_api_authentication(self):
        commands = FakeCommands(self)
        _, output = self.run_signed(commands, upload=True)
        self.assertEqual(commands.uploads, 1)
        self.assertEqual([options["destination"] for options in commands.export_options], ["export", "upload"])
        upload = [argv for argv, _ in commands.calls if "-exportArchive" in argv][-1]
        for value in ("-allowProvisioningUpdates", "-authenticationKeyPath", "-authenticationKeyID", "-authenticationKeyIssuerID"):
            self.assertIn(value, upload)
        self.assertEqual(upload[upload.index("-authenticationKeyID") + 1], META["key_id"])
        self.assertIn("for processing", output)
        self.assertIn("not yet confirmed", output)
        self.assert_clean(commands)

    def test_workflow_run_attempt_build_number_survives_archive_and_export(self):
        commands = FakeCommands(self)
        ipa, _ = self.run_signed(commands, build="42.1")
        self.assertEqual(ipa.parent.parent.name, "1.2.3-42.1")
        archive = next(argv for argv, _ in commands.calls if "archive" in argv)
        self.assertIn("CURRENT_PROJECT_VERSION=42.1", archive)
        self.assert_clean(commands)

    def test_cf_bundle_version_component_bounds(self):
        for build in ("1", "42.1", "1.0.0", "9999.99.99"):
            release.release_parameters("1.2.3", build, META["bundle_id"])
        for build in ("0", "0.1", "10000", "1.100", "1.2.100", "1.2.3.4", "1.01", "01.1"):
            with self.subTest(build=build), self.assertRaises(release.ReleaseError):
                release.release_parameters("1.2.3", build, META["bundle_id"])

    def test_prior_profile_bytes_mode_and_keychain_order_restore_after_success(self):
        self.profile.parent.mkdir(parents=True)
        self.profile.write_bytes(b"prior profile contents")
        self.profile.chmod(0o640)
        commands = FakeCommands(self)
        self.run_signed(commands)
        self.assertEqual(self.profile.read_bytes(), b"prior profile contents")
        self.assertEqual(stat.S_IMODE(self.profile.stat().st_mode), 0o640)
        self.assertFalse(self.share_profile.exists())
        self.assert_clean(commands)

    def test_cleanup_on_each_signing_archive_export_and_upload_failure(self):
        labels = (
            "Temporary keychain creation", "Temporary keychain settings", "Temporary keychain unlock",
            "Dedicated iOS certificate import", "Temporary signing key access", "Temporary iOS signing identity lookup",
            "Temporary keychain search list", "Signed iOS archive", "Archived iOS signature verification",
            "App Store IPA export", "App Store Connect upload",
        )
        self.profile.parent.mkdir(parents=True)
        self.profile.write_bytes(b"prior profile")
        self.profile.chmod(0o640)
        for index, label in enumerate(labels):
            with self.subTest(label=label):
                commands = FakeCommands(self, fail_label=label)
                with patch.object(
                    release.signing, "validate_ios_material", side_effect=self.validate_material
                ), \
                        patch.object(release, "command", side_effect=commands), \
                        patch.object(Path, "home", return_value=self.home), self.assertRaises(release.ReleaseError):
                    release.testflight(self.root, "1.2.3", str(100 + index), self.env, upload=True)
                self.assertEqual(self.profile.read_bytes(), b"prior profile")
                self.assertEqual(stat.S_IMODE(self.profile.stat().st_mode), 0o640)
                self.assertFalse(self.share_profile.exists())
                self.assert_clean(commands)

    def test_body_interruption_still_restores_signing_environment(self):
        commands = FakeCommands(self)
        with patch.object(release, "command", side_effect=commands), self.assertRaises(KeyboardInterrupt):
            with release.signing_environment(self.material(), self.runner, home=self.home):
                raise KeyboardInterrupt()
        self.assert_clean(commands)
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.share_profile.exists())

    def test_profile_install_failure_restores_prior_file_and_keychains(self):
        self.profile.parent.mkdir(parents=True)
        self.profile.write_bytes(b"prior profile")
        commands = FakeCommands(self)
        original_replace = release.replace_profile
        calls = 0

        def fail_install_once(*args):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("private fixture error")
            return original_replace(*args)

        with patch.object(release, "replace_profile", side_effect=fail_install_once), \
                patch.object(release, "command", side_effect=commands), self.assertRaises(OSError):
            with release.signing_environment(self.material(), self.runner, home=self.home):
                self.fail("Must not reach archive after failed provisioning profile install")
        self.assertEqual(self.profile.read_bytes(), b"prior profile")
        self.assert_clean(commands)

    def test_profile_symlink_is_rejected_before_keychain_changes(self):
        self.profile.parent.mkdir(parents=True)
        target = self.root / "untouched-profile"
        target.write_bytes(b"untouched")
        self.profile.symlink_to(target)
        with patch.object(release, "command") as command, self.assertRaises(release.ReleaseError):
            with release.signing_environment(self.material(), self.runner, home=self.home):
                self.fail("Unexpected signing setup")
        command.assert_not_called()
        self.assertEqual(target.read_bytes(), b"untouched")

    def test_cleanup_failure_is_reported_and_remaining_cleanup_still_runs(self):
        commands = FakeCommands(self, fail_label="Original keychain search list restoration")
        with patch.object(release, "command", side_effect=commands), self.assertRaisesRegex(release.ReleaseError, "restore"):
            with release.signing_environment(self.material(), self.runner, home=self.home):
                pass
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.share_profile.exists())
        self.assertEqual(list(self.runner.iterdir()), [])

    def test_archive_mismatch_missing_binary_framework_and_share_extension_block_export(self):
        for defect in ("version", "build", "bundle", "camera", "executable", "framework", "share", "archive"):
            with self.subTest(defect=defect):
                archive = self.root / defect / "Dieter.xcarchive"
                create_archive(archive)
                app = archive / "Products/Applications/Dieter.app"
                if defect in ("version", "build", "bundle", "camera"):
                    info = plistlib.loads((app / "Info.plist").read_bytes())
                    key = {"version": "CFBundleShortVersionString", "build": "CFBundleVersion",
                           "bundle": "CFBundleIdentifier", "camera": "NSCameraUsageDescription"}[defect]
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

    def test_wrong_exported_ipa_metadata_blocks_upload(self):
        commands = FakeCommands(self)
        with patch.object(release, "validate_ipa", side_effect=release.ReleaseError("Mismatched IPA metadata")), \
                self.assertRaises(release.ReleaseError):
            self.run_signed(commands, upload=True)
        self.assertEqual(commands.uploads, 0)
        self.assert_clean(commands)

    def test_ipa_validation_checks_count_metadata_framework_and_share_extension(self):
        for defect in ("missing", "extra", "invalid-zip", "metadata", "framework", "share"):
            with self.subTest(defect=defect):
                directory = self.root / ("ipa-" + defect)
                directory.mkdir()
                if defect == "invalid-zip":
                    (directory / "Dieter.ipa").write_bytes(b"invalid zip")
                elif defect != "missing":
                    with zipfile.ZipFile(directory / "Dieter.ipa", "w") as ipa:
                        info = {"CFBundleIdentifier": META["bundle_id"], "CFBundleShortVersionString": "1.2.3",
                                "CFBundleVersion": "wrong" if defect == "metadata" else "42",
                                "NSCameraUsageDescription": release.CAMERA_USAGE_DESCRIPTION}
                        ipa.writestr("Payload/Dieter.app/Info.plist", plistlib.dumps(info))
                        if defect != "framework":
                            ipa.writestr("Payload/Dieter.app/Frameworks/DieterIOS.framework/DieterIOS", b"framework")
                        if defect != "share":
                            ipa.writestr("Payload/Dieter.app/PlugIns/DieterShare.appex/DieterShare", b"share")
                    if defect == "extra":
                        (directory / "Extra.ipa").write_bytes(b"another zip")
                with self.assertRaises(release.ReleaseError):
                    release.validate_ipa(directory, "1.2.3", "42", META["bundle_id"])

    def test_identity_lookup_rejects_zero_multiple_and_wrong_certificate_types(self):
        for output in (b"0 valid identities found", f'1) {IDENTITY} "Developer ID Application: Fixture"'.encode(),
                       f'1) {IDENTITY} "Apple Distribution: A"\n2) {IDENTITY} "Apple Distribution: B"'.encode()):
            with self.subTest(output=output), patch.object(release, "command", return_value=output), \
                    self.assertRaises(release.ReleaseError):
                release.owned_identity(self.runner / "owned.keychain-db")

    def test_failed_external_commands_never_print_secrets_or_argv(self):
        result = subprocess.CompletedProcess([], 1, stdout=KEY, stderr=PASSWORD)
        with patch.dict(os.environ, self.env), patch.object(release.subprocess, "run", return_value=result) as run, \
                contextlib.redirect_stderr(io.StringIO()) as errors:
            with patch.object(release, "archive_unsigned", side_effect=lambda *args: release.command(
                    ["security", "import", PASSWORD.decode()], label="Signing fixture")):
                self.assertEqual(release.main(["archive-unsigned", "1.2.3", "42"]), 1)
        self.assertNotIn(KEY.decode(), errors.getvalue())
        self.assertNotIn(PASSWORD.decode(), errors.getvalue())
        self.assertFalse(set(release.SECRET_NAMES) & run.call_args.kwargs["env"].keys())

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
