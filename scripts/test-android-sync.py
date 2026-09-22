#!/usr/bin/env python3
"""Run native chat/sync integration against a disposable enrolled gateway.

The parent owns and reaps its fixture process and removes only its ADB reverse.
No production daemon, account, credentials, or attached phone is selected.
"""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time


def main():
    root = Path(__file__).resolve().parent.parent
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    if not serial.startswith("emulator-"):
        raise SystemExit("This fixture runs only on an explicitly selected emulator.")
    adb = [str(sdk / "platform-tools/adb"), "-s", serial]
    subprocess.run(adb + ["get-state"], check=True, timeout=10)
    env = dict(os.environ, ANDROID_SERIAL=serial, ANDROID_HOME=str(sdk))
    env.setdefault("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
    evidence = root / "tmp" / "performance-sync"
    evidence.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="android-", dir=evidence))
    print(f"Isolated sync evidence: {run}", flush=True)
    binary = run / "isolated-gateway"
    subprocess.run(["go", "build", "-o", str(binary), "./scripts/isolated-gateway"], cwd=root, check=True)
    fixture_state = tempfile.TemporaryDirectory(prefix="dieter-android-sync-")
    fixture = None
    port = None
    try:
        with (run / "fixture.log").open("w") as log:
            fixture = subprocess.Popen([str(binary), "--addr", "127.0.0.1:0", "--home", fixture_state.name],
                                       cwd=root, stdout=log, stderr=log)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                output = (run / "fixture.log").read_text()
                if "\nREADY\n" in output:
                    break
                if fixture.poll() is not None:
                    raise RuntimeError("Isolated gateway exited; inspect fixture.log")
                time.sleep(0.1)
            else:
                raise RuntimeError("Isolated gateway did not become ready")
            values = dict(line.split("=", 1) for line in output.splitlines() if line.startswith("DIETER_ISOLATED_"))
            port = values["DIETER_ISOLATED_ADDR"].rsplit(":", 1)[1]
            subprocess.run(adb + ["reverse", f"tcp:{port}", f"tcp:{port}"], check=True, timeout=10)
            classes = ",".join([
                "com.dbpprt.dieter.data.BackgroundTranscriptSyncIntegrationTest",
                "com.dbpprt.dieter.data.IsolatedGatewayIntegrationTest#sharedNavigationCachesOfflineEditsAndDrainsThroughRealGateway",
                "com.dbpprt.dieter.data.IsolatedGatewayIntegrationTest#terminalEditingControlBytesRoundTripThroughTheIsolatedGateway",
                "com.dbpprt.dieter.data.IsolatedGatewayIntegrationTest#queuedMessageRemovalReturnsAnEditableDraftEndToEnd",
                "com.dbpprt.dieter.data.IsolatedGatewayIntegrationTest#disconnectedCardStartPersistsAndDrainsThroughTheRealGateway",
            ])
            command = [str(root / "apps/android/gradlew"), "--project-dir", str(root / "apps/android"),
                       "connectedDebugAndroidTest",
                       f"-Pandroid.testInstrumentationRunnerArguments.class={classes}",
                       f"-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayPort={port}",
                       "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayHost=127.0.0.1",
                       "-Pandroid.testInstrumentationRunnerArguments.idleSampleMillis=30000",
                       "-Pandroid.testInstrumentationRunnerArguments.idleSampleWindows=2",
                       "-Pandroid.testInstrumentationRunnerArguments.isolatedGatewayToken=" + values["DIETER_ISOLATED_TOKEN"]]
            with (run / "tests.log").open("w") as tests:
                result = subprocess.run(command, cwd=root, env=env, stdout=tests, stderr=subprocess.STDOUT, timeout=600)
            shutil.copytree(root / "apps/android/app/build/outputs/androidTest-results/connected/debug",
                            run / "results", dirs_exist_ok=True)
            print((run / "tests.log").read_text()[-12000:], flush=True)
            result.check_returncode()
    finally:
        if port is not None:
            subprocess.run(adb + ["reverse", "--remove", f"tcp:{port}"], timeout=10, check=False)
        if fixture is not None and fixture.poll() is None:
            fixture.terminate()
            fixture.wait(timeout=30)
        fixture_state.cleanup()


if __name__ == "__main__":
    main()
