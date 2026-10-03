#!/usr/bin/env python3
"""Verify permission retention across two signed releases in an isolated LaunchAgent."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import sys
import time
import uuid


TEAM = "DS6N5L85E7"


def run(argv, *, timeout=45, check=True):
    result = subprocess.run([str(arg) for arg in argv], text=True,
                            capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{argv[0]} failed: {result.stdout}\n{result.stderr}")
    return result


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def verify_release(directory):
    hashes = {}
    for name, identifier in (("dieter", "com.dbpprt.dieter.daemon"),
                             ("dieter-capture", "com.dbpprt.dieter.capture")):
        binary = directory / name
        if binary.is_symlink() or not binary.is_file():
            raise RuntimeError(f"Expected regular executable: {binary}")
        requirement = (f'identifier "{identifier}" and anchor apple generic and '
                       'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
                       'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
                       f'certificate leaf[subject.OU] = "{TEAM}"')
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, binary])
        hashes[name] = digest(binary)
    run([directory / "dieter", "screen", "permissions", "--help"])
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-a", required=True, type=Path)
    parser.add_argument("--release-b", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path,
                        help="new directory, retained after the test")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("requires a disposable logged-in macOS account/VM")
    a, b = args.release_a.resolve(), args.release_b.resolve()
    hashes_a, hashes_b = verify_release(a), verify_release(b)
    if hashes_a["dieter"] == hashes_b["dieter"]:
        parser.error("A and B must contain differently built signed daemons")
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    runtime, home = evidence / "service", evidence / "data"
    label = "com.dbpprt.dieter.runtime-test." + uuid.uuid4().hex
    domain = f"gui/{os.getuid()}"
    job = f"{domain}/{label}"
    plist = evidence / "fixture.plist"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        address = f"127.0.0.1:{listener.getsockname()[1]}"
    executable = runtime / "bin/dieter"
    arguments = [str(executable), "--store", str(home), "daemon", "start",
                 "--service", "--runtime", str(runtime), "--addr", address]
    plist.write_bytes(plistlib.dumps({
        "Label": label, "ProgramArguments": arguments, "RunAtLoad": True,
        "KeepAlive": True, "ThrottleInterval": 3, "ProcessType": "Background",
        "EnvironmentVariables": {"HOME": str(Path.home()), "DIETER_HOME": str(home),
                                 "DIETER_REMOTE_DESKTOP_SOURCE": "screen",
                                 "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": str(evidence / "service.log"),
        "StandardErrorPath": str(evidence / "service.log"),
    }))
    report = {"releaseA": hashes_a, "releaseB": hashes_b, "label": label,
              "daemonPath": str(executable), "passed": False}
    loaded = False

    def cli(*command):
        return run([b / "dieter", "--store", home, "--timeout", "30s", *command], check=False)

    def wait_ready(expected_version):
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            result = cli("daemon", "status", "--format", "json")
            if result.returncode == 0:
                status = json.loads(result.stdout)
                if status.get("apiHealthy") and status.get("version") == expected_version:
                    return status
            time.sleep(0.25)
        raise RuntimeError("fixture did not become healthy with the expected release; inspect service.log")

    def start():
        nonlocal loaded
        run(["launchctl", "bootstrap", domain, plist])
        loaded = True

    def stop():
        nonlocal loaded
        if loaded:
            run(["launchctl", "bootout", job])
            loaded = False

    def probe(filename):
        result = cli("screen", "permissions")
        (evidence / filename).write_text(result.stdout + result.stderr)
        if result.returncode:
            return None
        value = json.loads(result.stdout)
        if value.get("daemonExecutable") != str(executable):
            raise RuntimeError("permission probe was attributed to a different executable")
        return value if value.get("captureVerified") and value.get("controlVerified") else None

    try:
        run([a / "dieter", "__service-stage", "--root", runtime], timeout=90)
        version_a = run([a / "dieter", "version"]).stdout.strip()
        version_b = run([b / "dieter", "version"]).stdout.strip()
        start()
        report["initialStatus"] = wait_ready(version_a)
        initial = probe("a-before-grant.json")
        if initial is None:
            print(f"Grant Screen Recording and Accessibility to:\n{executable}", flush=True)
            print("Only change the isolated fixture's entry. The harness never edits TCC.", flush=True)
            input("After granting access, press Return to restart this fixture and verify: ")
            stop()
            start()
            wait_ready(version_a)
            initial = probe("a-after-grant.json")
        if initial is None:
            raise RuntimeError("release A does not have both required permissions")
        report["releaseAProbe"] = initial
        running_a = wait_ready(version_a)
        run([b / "dieter", "__service-stage", "--root", runtime], timeout=90)
        if digest(executable) != hashes_a["dieter"]:
            raise RuntimeError("staging B changed the active A executable")
        report["stagedStatus"] = wait_ready(version_a)
        if report["stagedStatus"]["pid"] != running_a["pid"]:
            raise RuntimeError("staging unexpectedly restarted release A")
        stop()
        start()
        report["upgradedStatus"] = wait_ready(version_b)
        for name, expected in hashes_b.items():
            if digest(runtime / "bin" / name) != expected:
                raise RuntimeError(f"release B was not activated: {name}")
        upgraded = probe("b-without-new-grant.json")
        if upgraded is None:
            raise RuntimeError("permissions did not survive the signed upgrade; do not grant again for this test")
        report["releaseBProbe"] = upgraded
        stop()
        start()
        wait_ready(version_b)
        if probe("b-after-second-restart.json") is None:
            raise RuntimeError("permissions failed after a subsequent restart")
        report["passed"] = True
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        try:
            stop()
        except BaseException as error:
            report["passed"] = False
            report["cleanupError"] = str(error)
            raise
        finally:
            (evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Signed upgrade permissions passed. Evidence: {evidence / 'report.json'}")


if __name__ == "__main__":
    main()
