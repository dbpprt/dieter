"""Exercise the release signing credential gate without accessing real secrets."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
APPLICATION = (
    "CERTIFICATE_BASE64", "CERTIFICATE_PASSWORD", "NOTARY_KEY_BASE64",
    "NOTARY_KEY_ID", "NOTARY_ISSUER_ID",
)
INSTALLER = ("INSTALLER_CERTIFICATE_BASE64", "INSTALLER_CERTIFICATE_PASSWORD")
ANDROID = ("DIETER_ANDROID_KEYSTORE_PATH", "DIETER_ANDROID_KEYSTORE_PASSWORD",
           "DIETER_ANDROID_KEY_ALIAS", "DIETER_ANDROID_KEY_PASSWORD")


@unittest.skipUnless(shutil.which("just"), "Just is required")
class ReleaseSigningTests(unittest.TestCase):
    def check_config(self, names, installer=False, required=False):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            env = {key: value for key, value in os.environ.items()
                   if key not in APPLICATION + INSTALLER}
            env.update({name: "fixture-secret" for name in names})
            env["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run(
                ["just", "release", "signing-config", str(installer).lower(), str(required).lower()],
                cwd=ROOT, env=env, capture_output=True, text=True,
            )
            self.assertNotIn("fixture-secret", result.stdout + result.stderr)
            return result.returncode, output.read_text() if output.exists() else ""

    def test_unconfigured_release_keeps_existing_ad_hoc_path(self):
        for installer in (False, True):
            with self.subTest(installer=installer):
                self.assertEqual(self.check_config((), installer), (0, "enabled=false\n"))

    def test_application_configuration_is_independent_of_installer(self):
        self.assertEqual(self.check_config(APPLICATION), (0, "enabled=true\n"))

    def test_published_releases_require_signing_credentials(self):
        for installer in (False, True):
            with self.subTest(installer=installer):
                code, output = self.check_config((), installer, required=True)
                self.assertNotEqual(code, 0)
                self.assertEqual(output, "")
        self.assertEqual(self.check_config(APPLICATION, required=True),
                         (0, "enabled=true\n"))
        self.assertEqual(self.check_config(APPLICATION + INSTALLER, True, required=True),
                         (0, "enabled=true\n"))

    def test_daemon_requires_both_certificate_types(self):
        self.assertEqual(self.check_config(APPLICATION + INSTALLER, True),
                         (0, "enabled=true\n"))
        code, output = self.check_config(APPLICATION, True)
        self.assertNotEqual(code, 0)
        self.assertEqual(output, "")

    def test_each_missing_credential_blocks_partial_configuration(self):
        for installer, required in ((False, APPLICATION), (True, APPLICATION + INSTALLER)):
            for missing in required:
                with self.subTest(installer=installer, missing=missing):
                    code, output = self.check_config(
                        tuple(name for name in required if name != missing), installer,
                    )
                    self.assertNotEqual(code, 0)
                    self.assertEqual(output, "")


@unittest.skipUnless(shutil.which("just"), "Just is required")
class AndroidReleaseTests(unittest.TestCase):
    def test_signed_build_requires_every_credential_before_gradle(self):
        for missing in ANDROID:
            with self.subTest(missing=missing):
                env = {key: value for key, value in os.environ.items() if key not in ANDROID}
                env.update({key: "fixture-secret" for key in ANDROID if key != missing})
                result = subprocess.run(["just", "android", "build-release"],
                                        cwd=ROOT, env=env, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing + " is required", result.stderr)
                self.assertNotIn("fixture-secret", result.stdout + result.stderr)
                self.assertNotIn("Gradle", result.stdout + result.stderr)

    def verify(self, package="com.dbpprt.dieter", debuggable=False,
               manifest="E: manifest", signed=True):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory)
            build_tools = sdk / "build-tools/37.0.0"
            build_tools.mkdir(parents=True)
            signer = build_tools / "apksigner"
            signer.write_text('#!/bin/sh\n[ "$SIGNATURE_VALID" = true ]\n')
            signer.chmod(0o755)
            aapt = build_tools / "aapt2"
            aapt.write_text('#!/bin/sh\ncase "$2" in\n'
                            'badging) printf "%s\\n" "$APK_BADGING" ;;\n'
                            'xmltree) printf "%s\\n" "$APK_MANIFEST" ;;\n'
                            '*) exit 1 ;;\nesac\n')
            aapt.chmod(0o755)
            env = dict(os.environ, ANDROID_HOME=str(sdk),
                       SIGNATURE_VALID=str(signed).lower(),
                       APK_BADGING=f"package: name='{package}' versionCode='1'\n"
                       + ("application-debuggable\n" if debuggable else ""),
                       APK_MANIFEST=manifest)
            return subprocess.run(["just", "android", "verify-release", str(sdk / "app.apk")],
                                  cwd=ROOT, env=env, capture_output=True, text=True)

    def test_accepts_signed_production_package(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_test_packages_debugging_and_unsigned_apks(self):
        for arguments in ({"package": "com.dbpprt.dieter.e2e"},
                          {"package": "com.dbpprt.dieter.e2e.performance"},
                          {"debuggable": True}, {"signed": False},
                          {"manifest": "E: instrumentation"},
                          {"manifest": "com.dbpprt.dieter.e2e.DieterTestRunner"},
                          {"manifest": "androidx.compose.ui.test.TestActivity"}):
            with self.subTest(arguments=arguments):
                result = self.verify(**arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
