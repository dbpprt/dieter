import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.uname().sysname == "Linux", "Linux service lifecycle")
class LinuxServiceEndToEndTest(unittest.TestCase):
    def setUp(self):
        self.temporary = Path(tempfile.mkdtemp(prefix="dieter-linux-service-"))
        self.addCleanup(shutil.rmtree, self.temporary, ignore_errors=True)
        self.root = self.temporary / "home"
        self.config = self.temporary / "config"
        self.bin = self.temporary / "tools"
        self.bin.mkdir()
        self.executable = self.temporary / "dieter"
        subprocess.run(
            ["go", "build", "-o", str(self.executable), "./cmd/dieter"],
            cwd=ROOT,
            check=True,
        )
        self.capture_executable = self.temporary / "dieter-capture"
        subprocess.run(
            [str(ROOT / "native" / "linux-capture" / "build.sh"), str(self.capture_executable)],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        systemctl = self.bin / "systemctl"
        systemctl.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        systemctl.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "XDG_CONFIG_HOME": str(self.config),
                "PATH": f"{self.bin}:{self.environment['PATH']}",
            }
        )

    def test_managed_runtime_health_singleton_and_graceful_stop(self):
        install = subprocess.run(
            [
                str(self.executable),
                "--store",
                str(self.root),
                "daemon",
                "service",
                "install",
                "--no-start",
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(install.returncode, 0, install.stdout)
        managed = self.root / "service" / "bin" / "dieter"
        self.assertTrue(os.access(managed, os.X_OK))
        self.assertTrue(os.access(self.root / "service" / "bin" / "dieter-capture", os.X_OK))
        self.assertEqual((self.root.stat().st_mode & 0o777), 0o700)
        unit = self.config / "systemd" / "user" / "dieter.service"
        if systemd_analyze := shutil.which("systemd-analyze"):
            verification = subprocess.run(
                [systemd_analyze, "verify", str(unit)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(verification.returncode, 0, verification.stdout)
            self.assertNotIn("EnvironmentFile= path is not absolute", verification.stdout)

        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        daemon_environment = self.environment.copy()
        daemon_environment["DIETER_SERVICE_MANAGER"] = "fixture"
        daemon = subprocess.Popen(
            [
                str(managed),
                "--store",
                str(self.root),
                "daemon",
                "start",
                "--service",
                "--runtime",
                str(self.root / "service"),
                "--addr",
                f"127.0.0.1:{port}",
            ],
            env=daemon_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self.addCleanup(daemon.stdout.close)
        self.addCleanup(self._stop, daemon)
        deadline = time.monotonic() + 15
        last_error = None
        while time.monotonic() < deadline:
            if daemon.poll() is not None:
                self.fail(f"daemon exited early: {daemon.stdout.read()}")
            try:
                readiness = subprocess.run(
                    [str(self.executable), "--store", str(self.root), "daemon", "status", "--format", "json"],
                    env=self.environment,
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=True,
                )
                if json.loads(readiness.stdout)["running"]:
                    break
                last_error = readiness.stdout
            except Exception as error:  # bounded readiness probe
                last_error = error
            time.sleep(0.1)
        else:
            self.fail(f"daemon did not become healthy: {last_error}")

        status = subprocess.run(
            [str(self.executable), "--store", str(self.root), "daemon", "status", "--format", "json"],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        value = json.loads(status.stdout)
        self.assertTrue(value["running"])
        self.assertEqual(value["service"], "fixture")

        duplicate = subprocess.run(
            [
                str(self.executable),
                "--store",
                str(self.root),
                "daemon",
                "start",
                "--addr",
                "127.0.0.1:0",
            ],
            env=self.environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
        self.assertNotEqual(duplicate.returncode, 0, duplicate.stdout)
        self.assertIn("another Dieter daemon already owns", duplicate.stdout)

        daemon.send_signal(signal.SIGTERM)
        self.assertEqual(daemon.wait(timeout=25), 0, daemon.stdout.read())
        runtime_status = json.loads((self.root / "runtime" / "daemon.json").read_text(encoding="utf-8"))
        self.assertEqual(runtime_status["state"], "stopped")
        self.assertEqual(runtime_status["serviceManager"], "fixture")

    @staticmethod
    def _stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
