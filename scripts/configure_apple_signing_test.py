import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import configure_apple_signing as signing


class CredentialTransportTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
