#!/usr/bin/env python3
"""Run the Android Machines journey against a disposable gateway and daemon."""
import os
from pathlib import Path
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "apps/android/build/machines-evidence"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    executable = OUTPUT / "isolated-gateway"
    subprocess.run(["go", "build", "-o", str(executable), "./scripts/isolated-gateway"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="dieter-machines-") as fixture_home, (OUTPUT / "gateway.log").open("w") as log:
        fixture = subprocess.Popen(
            [str(executable), "--addr", "127.0.0.1:0", "--home", fixture_home],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
        )
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
        sdk = Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", str(Path.home() / "Library/Android/sdk"))))
        adb = str(sdk / "platform-tools/adb")
        serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
        try:
            if not ready.wait(60):
                raise RuntimeError("Isolated gateway did not become ready; see gateway.log")
            port = values["DIETER_ISOLATED_ADDR"].rsplit(":", 1)[1]
            subprocess.run([adb, "-s", serial, "reverse", f"tcp:{port}", f"tcp:{port}"], check=True)
            environment = dict(os.environ, ANDROID_SERIAL=serial)
            result = subprocess.run(
                [
                    str(ROOT / "apps/android/gradlew"),
                    "--project-dir",
                    str(ROOT / "apps/android"),
                    "connectedDebugAndroidTest",
                    "-Pandroid.testInstrumentationRunnerArguments.class=com.dbpprt.dieter.ui.MachinesEndToEndTest",
                    "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayPort=" + port,
                    "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayToken=" + values["DIETER_ISOLATED_TOKEN"],
                    "-Pandroid.testInstrumentationRunnerArguments.isolatedMachineId=" + values["DIETER_ISOLATED_DAEMON"],
                ],
                cwd=ROOT,
                env=environment,
                timeout=300,
            )
            if result.returncode:
                raise SystemExit(result.returncode)
        finally:
            if port:
                subprocess.run([adb, "-s", serial, "reverse", "--remove", f"tcp:{port}"], check=False)
            fixture.terminate()
            fixture.wait(timeout=20)


if __name__ == "__main__":
    main()
