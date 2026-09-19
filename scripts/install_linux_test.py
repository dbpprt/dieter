import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    os.uname().sysname == "Linux" and os.uname().machine == "x86_64",
    "portable installer fixture host",
)
class ReleaseInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = Path(tempfile.mkdtemp(prefix="dieter-linux-install-"))
        self.addCleanup(shutil.rmtree, self.temporary, ignore_errors=True)
        self.assets = self.temporary / "assets"
        self.bin = self.temporary / "bin"
        self.install = self.temporary / "install"
        self.assets.mkdir()
        self.bin.mkdir()
        self._create_asset("linux", "amd64", include_capture=True)
        self._create_asset("darwin", "arm64", include_capture=True)
        self._write_manifest()
        self._write_executable(
            "uname",
            """#!/bin/sh
set -eu
case "${1:-}" in
    -s) printf '%s\n' "$DIETER_TEST_UNAME_SYSTEM" ;;
    -m) printf '%s\n' "$DIETER_TEST_UNAME_MACHINE" ;;
    *) exit 2 ;;
esac
""",
        )
        self._write_executable(
            "curl",
            """#!/bin/sh
set -eu
url=""
destination=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) destination="$2"; shift 2 ;;
        http://*|https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >>"$DIETER_TEST_CURL_LOG"
cp "$DIETER_TEST_ASSETS/${url##*/}" "$destination"
""",
        )
        self._write_executable(
            "cosign",
            "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >\"$DIETER_TEST_COSIGN_LOG\"\n",
        )
        self._write_executable(
            "systemctl",
            "#!/bin/sh\nset -eu\n[ \"${1:-}\" = --user ]\n[ \"${2:-}\" = show-environment ]\n",
        )

    def _create_asset(self, system: str, architecture: str, include_capture: bool):
        package = self.temporary / f"dieter-{system}-{architecture}"
        package.mkdir()
        daemon = package / "dieter"
        daemon.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ -n \"${DIETER_TEST_DAEMON_LOG:-}\" ]; then\n"
            "    printf '%s\\n' \"$*\" >>\"$DIETER_TEST_DAEMON_LOG\"\n"
            "fi\n"
            "echo fixture\n",
            encoding="utf-8",
        )
        daemon.chmod(0o755)
        if include_capture:
            capture = package / "dieter-capture"
            capture.write_text("#!/bin/sh\necho capture fixture\n", encoding="utf-8")
            capture.chmod(0o755)
        (package / "LICENSE").write_text("fixture\n", encoding="utf-8")
        archive = self.assets / f"{package.name}.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(package, arcname=package.name)

    def _write_manifest(self):
        entries = []
        for archive in sorted(self.assets.glob("*.tar.gz")):
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            entries.append(f"{digest}  {archive.name}\n")
        (self.assets / "SHA256SUMS").write_text(
            "".join(entries), encoding="utf-8"
        )
        (self.assets / "SHA256SUMS.sigstore.json").write_text(
            '{"fixture":true}\n', encoding="utf-8"
        )

    def _write_executable(self, name: str, body: str):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def run_installer(
        self,
        *arguments: str,
        system: str = "Linux",
        machine: str = "x86_64",
    ):
        environment = os.environ.copy()
        for name in ("DIETER_INSTALL_DIR", "DIETER_NO_SERVICE", "DIETER_VERSION"):
            environment.pop(name, None)
        environment.update(
            {
                "PATH": f"{self.bin}:{environment['PATH']}",
                "DIETER_TEST_ASSETS": str(self.assets),
                "DIETER_TEST_COSIGN_LOG": str(self.temporary / "cosign.log"),
                "DIETER_TEST_CURL_LOG": str(self.temporary / "curl.log"),
                "DIETER_TEST_DAEMON_LOG": str(self.temporary / "daemon.log"),
                "DIETER_TEST_UNAME_SYSTEM": system,
                "DIETER_TEST_UNAME_MACHINE": machine,
                "HOME": str(self.temporary / "home"),
            }
        )
        if not arguments:
            arguments = ("--install-dir", str(self.install), "--no-service")
        return subprocess.run(
            ["sh", str(ROOT / "scripts" / "install.sh"), *arguments],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_signed_checksum_is_verified_before_atomic_install(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stdout)
        installed = self.install / "dieter"
        self.assertTrue(installed.is_file())
        self.assertTrue(os.access(installed, os.X_OK))
        capture = self.install / "dieter-capture"
        self.assertTrue(capture.is_file())
        self.assertTrue(os.access(capture, os.X_OK))
        invocation = (self.temporary / "cosign.log").read_text(encoding="utf-8")
        self.assertIn("verify-blob", invocation)
        self.assertIn("SHA256SUMS.sigstore.json", invocation)
        self.assertEqual(list(self.install.glob(".dieter.*")), [])

    def test_linux_managed_install_registers_user_service(self):
        result = self.run_installer("--install-dir", str(self.install))
        self.assertEqual(result.returncode, 0, result.stdout)
        invocation = (self.temporary / "daemon.log").read_text(encoding="utf-8")
        self.assertEqual(invocation, "daemon service install\n")

    def test_linux_release_requires_capture_helper(self):
        package = self.temporary / "dieter-linux-amd64"
        archive = self.assets / "dieter-linux-amd64.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            for name in ("dieter", "LICENSE"):
                output.add(package / name, arcname=f"{package.name}/{name}")
        self._write_manifest()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("linux release is missing its native capture helper", result.stdout)
        self.assertFalse((self.install / "dieter").exists())

    def test_apple_silicon_installs_capture_helper_without_linux_service(self):
        result = self.run_installer(
            "--version",
            "1.2.3",
            "--install-dir",
            str(self.install),
            "--no-service",
            system="Darwin",
            machine="arm64",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((self.install / "dieter").is_file())
        self.assertTrue((self.install / "dieter-capture").is_file())
        self.assertIn("portable macOS install", result.stdout)
        urls = (self.temporary / "curl.log").read_text(encoding="utf-8")
        self.assertIn(
            "/releases/download/v1.2.3/dieter-darwin-arm64.tar.gz", urls
        )
        self.assertFalse((self.temporary / "daemon.log").exists())

    def test_help_documents_targets_without_probing_host(self):
        result = self.run_installer("--help", system="unsupported", machine="unknown")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Linux amd64/arm64 and Apple Silicon macOS", result.stdout)

    def test_checksum_mismatch_is_rejected(self):
        (self.assets / "SHA256SUMS").write_text(
            f"{'0' * 64}  dieter-linux-amd64.tar.gz\n", encoding="utf-8"
        )
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Checksum verification failed", result.stdout)
        self.assertFalse((self.install / "dieter").exists())


if __name__ == "__main__":
    unittest.main()
