#!/usr/bin/env python3
"""Run Activity navigation with disposable gateway/daemon state and a mock agent."""
import os
from pathlib import Path
import subprocess
import threading
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "apps/android/build/activity-evidence"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    executable = OUTPUT / "isolated-gateway"
    subprocess.run(["go", "build", "-o", str(executable), "./scripts/isolated-gateway"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="dieter-activity-") as fixture_home, (OUTPUT / "gateway.log").open("w") as log:
        fixture = subprocess.Popen([str(executable), "--addr", "127.0.0.1:0", "--home", fixture_home], cwd=ROOT,
                                   stdout=subprocess.PIPE, stderr=log, text=True)
        values = {}
        ready = threading.Event()

        def read_ready():
            for line in fixture.stdout:
                if line.strip() == "READY":
                    ready.set()
                    return
                key, separator, value = line.strip().partition("=")
                if separator:
                    values[key] = value

        threading.Thread(target=read_ready, daemon=True).start()
        port = None
        adb = str(Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Library/Android/sdk")))) / "platform-tools/adb")
        try:
            if not ready.wait(60):
                raise RuntimeError("Isolated gateway did not become ready; see gateway.log")
            port = values["DIETER_ISOLATED_ADDR"].rsplit(":", 1)[1]
            subprocess.run([adb, "-s", "emulator-5554", "reverse", f"tcp:{port}", f"tcp:{port}"], check=True)
            environment = dict(os.environ, ANDROID_SERIAL="emulator-5554")
            result = subprocess.run([
                str(ROOT / "apps/android/gradlew"), "--project-dir", str(ROOT / "apps/android"),
                "connectedDebugAndroidTest",
                "-Pandroid.testInstrumentationRunnerArguments.class=com.dbpprt.dieter.ui.ActivityEndToEndTest",
                "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayPort=" + port,
                "-Pandroid.testInstrumentationRunnerArguments.isolatedBoardId=" + values["DIETER_ISOLATED_BOARD"],
                "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayToken=" + values["DIETER_ISOLATED_TOKEN"],
            ], cwd=ROOT, env=environment, timeout=240)
            if result.returncode:
                raise SystemExit(result.returncode)
        finally:
            if port:
                subprocess.run([adb, "-s", "emulator-5554", "reverse", "--remove", f"tcp:{port}"], check=False)
            fixture.terminate()
            fixture.wait(timeout=20)


if __name__ == "__main__":
    main()
