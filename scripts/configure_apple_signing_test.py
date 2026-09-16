import argparse
import base64
import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import configure_apple_signing as signing


class CredentialTransportTests(unittest.TestCase):
    def test_platform_selects_only_explicit_credentials(self):
        for platform, expected in (("macos", {"MAC_SECRET": b"mac"}),
                                   ("ios", {"IOS_SECRET": b"ios"}),
                                   ("all", {"MAC_SECRET": b"mac", "IOS_SECRET": b"ios"})):
            with self.subTest(platform=platform), \
                    patch.object(signing, "build_macos_secrets", return_value={"MAC_SECRET": b"mac"}) as mac, \
                    patch.object(signing, "build_ios_secrets", return_value={"IOS_SECRET": b"ios"}) as ios:
                self.assertEqual(signing.build_secrets(argparse.Namespace(platform=platform)), expected)
                self.assertEqual(mac.call_count, int(platform in ("macos", "all")))
                self.assertEqual(ios.call_count, int(platform in ("ios", "all")))

    def test_ios_check_does_not_require_mac_or_contact_github(self):
        argv = ["--platform", "ios", "--ios-distribution-p12", "dedicated-ios.p12",
                "--ios-provisioning-profile", "dedicated.mobileprovision", "--ios-api-key", "ios.p8",
                "--ios-key-id", "ABCDEFGHIJ", "--ios-issuer-id", "52e72a38-f9bd-43be-bf43-311937e963bd", "--check"]
        with patch.object(signing, "build_secrets", return_value={"SECRET": b"private"}) as build, \
                patch.object(signing, "upload_secrets") as upload, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(signing.main(argv), 0)
        self.assertEqual(build.call_args.args[0].ios_bundle_id, "com.dbpprt.dieter.ios")
        upload.assert_not_called()

    def test_missing_platform_inputs_are_rejected_before_validation(self):
        for platform, required in (("macos", "--application-p12"), ("ios", "--ios-distribution-p12"),
                                   ("all", "--ios-api-key")):
            with self.subTest(platform=platform), patch.object(signing, "build_secrets") as build, \
                    contextlib.redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(SystemExit) as result:
                    signing.main(["--platform", platform, "--check"])
                self.assertEqual(result.exception.code, 2)
                self.assertIn(required, errors.getvalue())
                build.assert_not_called()

    def test_secrets_use_stdin_and_preflight_precedes_writes(self):
        secrets = {"MACOS_TEST_ONE": b"a secret value", "MACOS_TEST_TWO": b"another secret"}
        calls = []

        def command(argv, data=None, **kwargs):
            calls.append((argv, data))
            if argv[1:3] == ["secret", "list"]:
                return json.dumps([{"name": name} for name in secrets]).encode()
            return b""

        with patch.object(signing, "run_command", side_effect=command), contextlib.redirect_stdout(io.StringIO()) as output:
            signing.upload_secrets("dbpprt/dieter", secrets)
        self.assertEqual(calls[0][0][1:3], ["auth", "status"])
        self.assertEqual(calls[1][0][1:3], ["secret", "list"])
        for (name, value), (argv, data) in zip(secrets.items(), calls[2:4]):
            self.assertEqual(argv, ["gh", "secret", "set", name, "--repo", "https://github.com/dbpprt/dieter"])
            self.assertEqual(data, value)
            self.assertNotIn(value.decode(), output.getvalue())
            self.assertNotIn(value.decode(), " ".join(argv))

    def test_failed_preflight_does_not_upload(self):
        with patch.object(signing, "run_command", side_effect=signing.SetupError("no access")) as command:
            with self.assertRaises(signing.SetupError):
                signing.upload_secrets("dbpprt/dieter", {"SECRET": b"private"})
        self.assertEqual(command.call_count, 1)

    def test_missing_post_upload_secret_is_reported(self):
        with patch.object(signing, "run_command", return_value=b"[]"), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(signing.SetupError, "not returned"):
                signing.upload_secrets("dbpprt/dieter", {"SECRET": b"private"})

    def test_subprocess_errors_never_echo_output_or_input(self):
        result = subprocess.CompletedProcess([], 1, b"private output", b"private error")
        with patch.object(signing.subprocess, "run", return_value=result) as command:
            with self.assertRaises(signing.SetupError) as caught:
                signing.run_command(["gh", "secret", "set", "SECRET"], b"private input", label="Upload")
        self.assertNotIn("private", str(caught.exception))
        self.assertEqual(command.call_args.kwargs["input"], b"private input")

    def test_check_does_not_contact_github(self):
        argv = ["--application-p12", "dedicated-app.p12", "--installer-p12", "dedicated-installer.p12",
                "--notary-key", "dedicated.p8", "--key-id", "ABCDEFGHIJ", "--issuer-id",
                "52e72a38-f9bd-43be-bf43-311937e963bd", "--check"]
        with patch.object(signing, "build_secrets", return_value={"SECRET": b"private"}), \
                patch.object(signing, "upload_secrets") as upload, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(signing.main(argv), 0)
        upload.assert_not_called()
        self.assertIn("Nothing uploaded", output.getvalue())

    def test_password_file_rejects_shared_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "password"
            path.write_bytes(b"not-a-real-password\n")
            path.chmod(0o644)
            with self.assertRaisesRegex(signing.SetupError, "permissions"):
                signing.password_for(path, "Application")
            path.chmod(0o600)
            self.assertEqual(signing.password_for(path, "Application"), b"not-a-real-password")
            linked = Path(directory) / "symlink"
            linked.symlink_to(path)
            with self.assertRaises(signing.SetupError):
                signing.password_for(linked, "Application")

    def test_secret_size_is_checked_after_base64_encoding(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oversize"
            path.write_bytes(b"x" * (signing.MAX_SECRET_BYTES * 3 // 4 + 1))
            with self.assertRaisesRegex(signing.SetupError, "size limit"):
                signing.read_credential(path, "Fixture")

    def test_password_uses_a_private_descriptor(self):
        observed = []

        def command(argv, data=None, **kwargs):
            descriptor, = kwargs["pass_fds"]
            observed.append((argv, data, os.read(descriptor, 1024)))
            return b"synthetic PEM"

        with patch.object(signing, "run_command", side_effect=command):
            self.assertEqual(signing.decode_p12(b"synthetic p12", b"private password", "Fixture"), b"synthetic PEM")
        argv, data, password = observed[0]
        self.assertEqual(password, b"private password\n")
        self.assertEqual(data, b"synthetic p12")
        self.assertNotIn("private password", " ".join(argv))


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required for synthetic certificate validation")
class CertificateValidationTests(unittest.TestCase):
    """Only freshly generated synthetic credentials; no Apple account or keychain."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.password = b"synthetic-test-password"

    def openssl(self, *args, data=None):
        return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout

    def certificate(self, kind, team="ABCDE12345", *, compatible=True):
        key_path = self.root / f"{kind}-{team}.key"
        certificate_path = self.root / f"{kind}-{team}.crt"
        p12_path = self.root / f"{kind}-{team}.p12"
        oid = "1.2.840.113635.100.6.1.13" if kind == "Application" else "1.2.840.113635.100.6.1.14"
        self.openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                     "-keyout", str(key_path), "-out", str(certificate_path), "-days", "1",
                     "-subj", f"/CN=Developer ID {kind}: Synthetic Fixture/OU={team}",
                     "-addext", oid + "=DER:05:00", "-addext", "basicConstraints=critical,CA:FALSE")
        self.openssl("pkcs12", "-export", "-inkey", str(key_path), "-in", str(certificate_path),
                     "-out", str(p12_path), "-passout", "stdin",
                     *(["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"]
                       if compatible else []), data=self.password + b"\n")
        return p12_path

    def test_application_and_installer_and_wrong_type(self):
        for kind in ("Application", "Installer"):
            p12 = self.certificate(kind).read_bytes()
            self.assertEqual(signing.validate_p12(p12, self.password, kind), b"ABCDE12345")
            wrong = "Installer" if kind == "Application" else "Application"
            with self.assertRaisesRegex(signing.SetupError, "wrong Apple certificate type"):
                signing.validate_p12(p12, self.password, wrong)
            with self.assertRaises(signing.SetupError):
                signing.validate_p12(p12, b"wrong password", kind)

    def test_different_teams_fail_before_upload(self):
        application = self.certificate("Application")
        installer = self.certificate("Installer", team="OTHER12345")
        notary = self.root / "test.p8"
        notary.write_bytes(self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"))
        args = argparse.Namespace(application_p12=application, installer_p12=installer, notary_key=notary,
                                  application_password_file=None, installer_password_file=None,
                                  key_id="ABCDEFGHIJ", issuer_id="52e72a38-f9bd-43be-bf43-311937e963bd")
        with patch.object(signing, "password_for", return_value=self.password):
            with self.assertRaisesRegex(signing.SetupError, "same Apple team"):
                signing.build_secrets(args)

    def test_keychain_legacy_p12_export(self):
        self.certificate("Application")
        legacy_path = self.root / "legacy.p12"
        result = subprocess.run(
            ["openssl", "pkcs12", "-export", "-legacy", "-inkey", str(self.root / "Application-ABCDE12345.key"),
             "-in", str(self.root / "Application-ABCDE12345.crt"), "-out", str(legacy_path), "-passout", "stdin"],
            input=self.password + b"\n", capture_output=True)
        if result.returncode:
            self.skipTest("This OpenSSL does not support the -legacy fixture option")
        self.assertEqual(signing.validate_p12(legacy_path.read_bytes(), self.password, "Application"), b"ABCDE12345")

    def test_openssl_three_defaults_fail_with_mac_export_guidance(self):
        if not self.openssl("version").startswith(b"OpenSSL 3."):
            self.skipTest("The incompatible default fixture requires OpenSSL 3")
        p12 = self.certificate("Application", compatible=False).read_bytes()
        # A successful OpenSSL decode alone is not sufficient for macOS import.
        self.assertIn(b"BEGIN PRIVATE KEY", signing.decode_p12(p12, self.password, "Fixture"))
        with self.assertRaisesRegex(signing.SetupError, "-keypbe PBE-SHA1-3DES") as caught:
            signing.validate_p12(p12, self.password, "Application")
        self.assertIn("-macalg sha1", str(caught.exception))
        self.assertNotIn(self.password.decode(), str(caught.exception))

    def test_sha256_mac_is_rejected_even_with_compatible_encryption(self):
        self.certificate("Application")
        p12 = self.openssl("pkcs12", "-export", "-inkey", str(self.root / "Application-ABCDE12345.key"),
                           "-in", str(self.root / "Application-ABCDE12345.crt"), "-passout", "stdin",
                           "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha256",
                           data=self.password + b"\n")
        with self.assertRaisesRegex(signing.SetupError, "incompatible with macOS import"):
            signing.validate_p12(p12, self.password, "Application")

    def test_incompatible_p12_is_rejected_before_github_access(self):
        if not self.openssl("version").startswith(b"OpenSSL 3."):
            self.skipTest("The incompatible default fixture requires OpenSSL 3")
        application = self.certificate("Application", compatible=False)
        installer = self.certificate("Installer")
        notary = self.root / "test.p8"
        notary.write_bytes(self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"))
        args = ["--application-p12", str(application), "--installer-p12", str(installer),
                "--notary-key", str(notary), "--key-id", "ABCDEFGHIJ", "--issuer-id",
                "52e72a38-f9bd-43be-bf43-311937e963bd"]
        with patch.object(signing, "password_for", return_value=self.password), \
                patch.object(signing, "upload_secrets") as upload, contextlib.redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(signing.main(args), 1)
        upload.assert_not_called()
        self.assertIn("incompatible with macOS import", errors.getvalue())
        self.assertNotIn(self.password.decode(), errors.getvalue())


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required for synthetic iOS signing validation")
class IOSCertificateValidationTests(unittest.TestCase):
    """Synthetic CMS/P12/P256 material only; no Apple credentials or Keychain."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.password = b"synthetic-ios-password"
        self.team = "ABCDE12345"
        self.bundle = "com.dbpprt.dieter.ios"
        self.key_id = "ABCDEFGHIJ"
        self.issuer = "52e72a38-f9bd-43be-bf43-311937e963bd"
        self.key_path = self.root / "signing.key"
        self.cert_path = self.root / "signing.crt"
        self.openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                     "-keyout", str(self.key_path), "-out", str(self.cert_path), "-days", "1",
                     "-subj", f"/CN=Apple Distribution: Synthetic Fixture/OU={self.team}",
                     "-addext", "1.2.840.113635.100.6.1.4=DER:05:00",
                     "-addext", "basicConstraints=critical,CA:FALSE")
        self.p12 = self.export_p12()
        self.api_key = self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
        self.profile = {
            "UUID": "536D3AEE-EAFE-41C2-8A85-A82E4B7B9B4F", "Name": "Dieter iOS App Store",
            "TeamIdentifier": [self.team], "ApplicationIdentifierPrefix": [self.team], "Platform": ["iOS"],
            "CreationDate": datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(minutes=1),
            "ExpirationDate": datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=1),
            "DeveloperCertificates": [self.openssl("x509", "-in", str(self.cert_path), "-outform", "DER")],
            "Entitlements": {"application-identifier": f"{self.team}.{self.bundle}",
                             "com.apple.developer.team-identifier": self.team,
                             "get-task-allow": False, "beta-reports-active": True},
        }

    def openssl(self, *args, data=None):
        return subprocess.run(["openssl", *args], input=data, capture_output=True, check=True).stdout

    def export_p12(self, *, compatible=True):
        return self.openssl("pkcs12", "-export", "-inkey", str(self.key_path), "-in", str(self.cert_path),
                            "-passout", "stdin", *(["-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                                                     "-macalg", "sha1"] if compatible else []),
                            data=self.password + b"\n")

    def cms(self, profile=None):
        return self.openssl("cms", "-sign", "-binary", "-outform", "DER", "-nodetach",
                            "-signer", str(self.cert_path), "-inkey", str(self.key_path),
                            data=plistlib.dumps(self.profile if profile is None else profile))

    def validate(self, **overrides):
        arguments = dict(distribution_p12=self.p12, distribution_password=self.password,
                         provisioning_profile=self.cms(), api_key=self.api_key, key_id=self.key_id,
                         issuer_id=self.issuer, bundle_id=self.bundle)
        arguments.update(overrides)
        return signing.validate_ios_material(**arguments)

    def test_valid_material_returns_release_metadata_without_import(self):
        real_command = signing.run_command
        with patch.object(signing, "run_command", wraps=real_command) as command:
            metadata = self.validate(team_id=self.team)
        self.assertEqual(metadata, {"team_id": self.team, "bundle_id": self.bundle,
                                    "profile_uuid": self.profile["UUID"], "profile_name": self.profile["Name"],
                                    "key_id": self.key_id, "issuer_id": self.issuer})
        self.assertTrue(all(call.args[0][0] == "openssl" for call in command.call_args_list))
        self.assertNotIn(self.password, repr(command.call_args_list).encode())

    def test_lowercase_profile_uuid_is_preserved_for_xcode_lookup(self):
        self.profile["UUID"] = self.profile["UUID"].lower()
        self.assertEqual(self.validate()["profile_uuid"], self.profile["UUID"])

    def test_profile_uuid_requires_canonical_hyphenated_spelling(self):
        original = self.profile["UUID"]
        for value in (original.replace("-", ""), "{" + original + "}", "urn:uuid:" + original, 123):
            with self.subTest(value=value):
                self.profile["UUID"] = value
                with self.assertRaisesRegex(signing.SetupError, "valid UUID"):
                    self.validate()

    def test_ios_secret_names_and_encoded_material(self):
        profile = self.cms()
        paths = {}
        for name, data in (("distribution", self.p12), ("profile", profile), ("api", self.api_key)):
            path = self.root / name
            path.write_bytes(data)
            paths[name] = path
        args = argparse.Namespace(ios_distribution_p12=paths["distribution"], ios_provisioning_profile=paths["profile"],
                                  ios_api_key=paths["api"], ios_distribution_password_file=None,
                                  ios_key_id=self.key_id, ios_issuer_id=self.issuer, ios_bundle_id=self.bundle)
        with patch.object(signing, "password_for", return_value=self.password):
            secrets = signing.build_ios_secrets(args)
        self.assertEqual(secrets, {
            "IOS_DISTRIBUTION_CERTIFICATE_BASE64": base64.b64encode(self.p12),
            "IOS_DISTRIBUTION_CERTIFICATE_PASSWORD": self.password,
            "IOS_PROVISIONING_PROFILE_BASE64": base64.b64encode(profile),
            "IOS_APP_STORE_CONNECT_KEY_BASE64": base64.b64encode(self.api_key),
            "IOS_APP_STORE_CONNECT_KEY_ID": self.key_id.encode(),
            "IOS_APP_STORE_CONNECT_ISSUER_ID": self.issuer.encode(),
            "IOS_TEAM_ID": self.team.encode(), "IOS_BUNDLE_ID": self.bundle.encode(),
        })

    def test_distribution_type_and_matching_key_are_required(self):
        wrong_certificate = self.cert_path.read_bytes()
        original = signing.run_command

        def wrong_type(argv, *args, **kwargs):
            result = original(argv, *args, **kwargs)
            return result.replace(b"Apple Distribution:", b"Developer ID Application:")

        with patch.object(signing, "run_command", side_effect=wrong_type):
            with self.assertRaisesRegex(signing.SetupError, "wrong Apple certificate type"):
                self.validate()
        wrong_key = self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256")
        with patch.object(signing, "decode_p12", side_effect=lambda *a, **k: b"MAC: sha1" if k.get("info") else wrong_certificate + wrong_key):
            with self.assertRaisesRegex(signing.SetupError, "does not match its private key"):
                self.validate()

    def test_wrong_team_bundle_or_certificate_are_rejected(self):
        with self.assertRaisesRegex(signing.SetupError, "team ID"):
            self.validate(team_id="OTHER12345")
        for field, value, message in (("TeamIdentifier", ["OTHER12345"], "same Apple team"),
                                      ("DeveloperCertificates", [b"another certificate"], "does not include")):
            with self.subTest(field=field):
                changed = dict(self.profile, **{field: value})
                with self.assertRaisesRegex(signing.SetupError, message):
                    self.validate(provisioning_profile=self.cms(changed))
        with self.assertRaisesRegex(signing.SetupError, "exact iOS bundle ID"):
            self.validate(bundle_id="com.dbpprt.other")
        with self.assertRaisesRegex(signing.SetupError, "without wildcards"):
            self.validate(bundle_id="com.dbpprt.*")
        self.profile["Entitlements"]["application-identifier"] = f"{self.team}.*"
        with self.assertRaisesRegex(signing.SetupError, "exact iOS bundle ID"):
            self.validate()

    def test_development_adhoc_enterprise_and_wrong_platform_fail(self):
        for field, value in (("ProvisionedDevices", []), ("ProvisionedDevices", ["synthetic-device"]),
                             ("ProvisionsAllDevices", True), ("Platform", ["OSX"])):
            with self.subTest(field=field, value=value):
                with self.assertRaisesRegex(signing.SetupError, "App Store distribution"):
                    self.validate(provisioning_profile=self.cms(dict(self.profile, **{field: value})))
        for field, value in (("get-task-allow", True), ("beta-reports-active", False)):
            changed = dict(self.profile, Entitlements=dict(self.profile["Entitlements"], **{field: value}))
            with self.assertRaisesRegex(signing.SetupError, "App Store distribution"):
                self.validate(provisioning_profile=self.cms(changed))

    def test_profile_expiration_uuid_name_and_signature_are_checked(self):
        for field, value, message in (("ExpirationDate", datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=1), "has expired"),
                                      ("CreationDate", datetime.now(timezone.utc).replace(tzinfo=None) + timedelta(days=1), "not yet valid"),
                                      ("UUID", "../../unsafe", "valid UUID"), ("Name", "", "valid name")):
            with self.subTest(field=field):
                with self.assertRaisesRegex(signing.SetupError, message):
                    self.validate(provisioning_profile=self.cms(dict(self.profile, **{field: value})))
        with self.assertRaisesRegex(signing.SetupError, "CMS signature"):
            self.validate(provisioning_profile=plistlib.dumps(self.profile))
        changed = self.cms().replace(self.bundle.encode(), b"com.dbpprt.other.ios")
        with self.assertRaisesRegex(signing.SetupError, "CMS signature"):
            self.validate(provisioning_profile=changed)

    def test_invalid_api_identifiers_and_non_p256_key_fail(self):
        for overrides, message in (({"key_id": "invalid"}, "Key ID"), ({"issuer_id": "invalid"}, "Issuer ID")):
            with self.assertRaisesRegex(signing.SetupError, message):
                self.validate(**overrides)
        key = self.openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-384")
        with self.assertRaisesRegex(signing.SetupError, "P-256"):
            self.validate(api_key=key)

    def test_incompatible_p12_and_wrong_password_fail(self):
        with self.assertRaises(signing.SetupError):
            self.validate(distribution_password=b"not the password")
        if self.openssl("version").startswith(b"OpenSSL 3."):
            with self.assertRaisesRegex(signing.SetupError, "incompatible with macOS import"):
                self.validate(distribution_p12=self.export_p12(compatible=False))

    def test_expired_distribution_certificate_fails_before_profile_validation(self):
        (self.root / "index").write_text("")
        (self.root / "serial").write_text("01\n")
        config = self.root / "ca.cnf"
        config.write_text(f"""[ca]
default_ca = fixture
[fixture]
database = {self.root / 'index'}
serial = {self.root / 'serial'}
new_certs_dir = {self.root}
private_key = {self.key_path}
certificate = {self.cert_path}
default_md = sha256
policy = fixture_policy
x509_extensions = distribution
[fixture_policy]
commonName = supplied
organizationalUnitName = supplied
[distribution]
1.2.840.113635.100.6.1.4 = DER:05:00
basicConstraints = critical,CA:FALSE
""")
        request = self.openssl("req", "-new", "-key", str(self.key_path),
                               "-subj", f"/CN=Apple Distribution: Synthetic Fixture/OU={self.team}")
        expired = self.openssl("ca", "-batch", "-selfsign", "-notext", "-config", str(config),
                               "-in", "/dev/stdin", "-startdate", "20200101000000Z", "-enddate", "20200102000000Z", data=request)
        self.cert_path.write_bytes(expired)
        with self.assertRaisesRegex(signing.SetupError, "Apple Distribution certificate failed"):
            self.validate(distribution_p12=self.export_p12())

    def test_future_certificate_and_unsafe_password_fail(self):
        original = signing.run_command

        def future_start(argv, *args, **kwargs):
            if "-startdate" in argv:
                return b"notBefore=Jan  1 00:00:00 2099 GMT\n"
            return original(argv, *args, **kwargs)

        with patch.object(signing, "run_command", side_effect=future_start):
            with self.assertRaisesRegex(signing.SetupError, "not yet valid"):
                self.validate()
        for password in (b"", b"split\npassword", b"nul\0password", b"x" * 1025):
            with self.subTest(password_length=len(password)):
                with self.assertRaisesRegex(signing.SetupError, "nonempty single line"):
                    self.validate(distribution_password=password)


if __name__ == "__main__":
    unittest.main()
