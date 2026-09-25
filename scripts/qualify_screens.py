#!/usr/bin/env python3
"""Run isolated screen fixtures and produce an honest, versioned qualification record.

No live daemon changes, shell commands from manifests, or automatic promotion.
Missing required evidence is a failure even if the underlying command exits zero.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = re.compile(r"(?:Native screen|HEVC transport|Codec integration|Screen integration|Recovery integration|Decoder SDK|E2E) evidence: (/.+)")
ALLOWED_ARTIFACT = re.compile(r"(?:latency|input-latency|render-trace|stats|mac-stats|decoder-H26[45]|decoder-sdk|recovery)\.json|(?:viewer|hevc|recovery-H26[45]|canvas-(?:fit|pan|pinch))\.png")
SWITCHES = {"DIETER_SCREEN_CONTENT_ADAPTATION", "DIETER_SCREEN_OVERLAP", "DIETER_SCREEN_ENCODER_BURST_MS", "DIETER_SCREEN_FEC", "DIETER_SCREEN_LTR", "DIETER_SCREEN_FAST_BITRATE"}


def command(case, serial):
    env = {}
    runner = case["runner"]
    if runner == "native":
        argv = ["just", "mac", "screens-native-test"]
    elif runner in ("mac-latency", "mac-recovery", "mac-journey"):
        argv = ["just", "mac", "screens-test"]
        if runner == "mac-latency":
            env.update(DIETER_TEST_SCREEN_LATENCY_ONLY="1", DIETER_SCREEN_RENDER_TRACE="1",
                       DIETER_TEST_SCREEN_INPUT_SAMPLES=str(case.get("samples", 200)))
        if runner == "mac-recovery":
            env["DIETER_TEST_SCREEN_RECOVERY"] = "1"
        if case.get("capture", "synthetic") == "screen":
            env["DIETER_TEST_SCREEN_CAPTURE_REAL"] = "1"
        env["DIETER_TEST_SCREEN_CODEC"] = case.get("codec", "h264")
        env["DIETER_TEST_SCREEN_FPS"] = str(case.get("fps", 60))
        env["DIETER_SCREEN_PRESENTATION"] = case.get("presentation", "immediate")
        if env["DIETER_SCREEN_PRESENTATION"] not in ("immediate", "bounded", "low-latency", "display-link"):
            raise ValueError("Unknown presentation policy")
    elif runner in ("android-codec", "android-journey", "android-recovery", "android-sdk"):
        if not serial or serial.startswith("emulator-"):
            raise ValueError("Physical Android cases require an explicit physical --serial")
        selection = {
            "android-sdk": ["--suite", "sdk"],
            "android-codec": ["--case", "screens.screen-codec-end-to-end-test"],
            "android-journey": ["--case", "screens.screen-end-to-end-test"],
            "android-recovery": ["--case", "screens.screen-recovery-end-to-end-test"],
        }[runner]
        argv = ["just", "e2e", "run", "--serial", serial, *selection]
        env.update(
                   DIETER_SCREEN_TEST_LOW_LATENCY="1" if case.get("lowLatency", True) else "0",
                   DIETER_SCREEN_TEST_SURFACE="1" if case.get("surfaceView", False) else "0",
                   DIETER_SCREEN_TEST_DIRECT_SURFACE="1" if case.get("directSurface", False) else "0",
                   DIETER_SCREEN_TEST_SOURCE=case.get("capture", "native-synthetic"))
    else:
        raise ValueError("Unknown runner: " + runner)
    for key, value in case.get("switches", {}).items():
        if key not in SWITCHES:
            raise ValueError("Unknown experiment: " + key)
        allowed = ("0", "100", "250", "500") if key == "DIETER_SCREEN_ENCODER_BURST_MS" else ("0", "1")
        if str(value) not in allowed:
            raise ValueError("Unsupported experiment value: " + key)
        env[key] = str(value)
    return argv, env


def collect(log, directory):
    artifacts = []
    for index, source in enumerate(dict.fromkeys(EVIDENCE.findall(log))):
        source = Path(source)
        if not source.name.startswith(("dieter-", "e2e-")) or source.is_symlink() or not source.is_dir():
            continue
        # Capture only non-secret measurement files. ready/test JSON contain
        # disposable credentials and deliberately never enter the report.
        paths = list(source.iterdir())
        if source.name.startswith("e2e-"):
            paths += [path for child in source.iterdir() if child.is_dir() and not child.is_symlink()
                      for path in child.iterdir()]
        for artifact_index, path in enumerate(sorted(paths)):
            if not ALLOWED_ARTIFACT.fullmatch(path.name) or path.is_symlink() or path.stat().st_size > 16 << 20:
                continue
            target = directory / f"{index}-{artifact_index}-{path.name}"
            shutil.copyfile(path, target)
            artifacts.append(target.name)
    return artifacts


def metrics(directory, artifacts):
    for name in artifacts:
        if name.endswith(("-latency.json", "-input-latency.json")):
            value = json.loads((directory / name).read_text())
            if "inputP95Ms" in value:
                return value
    return {}


def finite_number(value, minimum=0):
    return type(value) in (int, float) and math.isfinite(value) and value >= minimum


def source_fingerprint():
    paths = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
    source = hashlib.sha256()
    for name in sorted(set(paths)):
        path = ROOT / name
        if name and path.is_file() and not path.is_symlink():
            source.update(name.encode() + b"\0" + hashlib.sha256(path.read_bytes()).digest())
    return source.hexdigest()


def complete_mac_recovery(log):
    cells = set(re.findall(r"RECOVERY codec=(H26[45]) mode=(baseline|ltr|fec|both) frames=[1-9][0-9]* ", log))
    expected = {(codec, mode) for codec in ("H264", "H265") for mode in ("baseline", "ltr", "fec", "both")}
    proofs = re.findall(r"FEC PROOF codec=(H26[45]) decoded RTP timestamp=[0-9]+ with original and retransmissions discarded", log)
    return (cells == expected and all(proofs.count(codec) == 2 for codec in ("H264", "H265"))
            and "✔ Test remoteDesktopRecoveryAuthenticatedTransport() passed" in log)


def recovery_evidence_error(directory, artifacts):
    """A filename or test-runner exit code cannot prove decoded recovery."""
    names = [name for name in artifacts if name.endswith("-recovery.json")]
    if len(names) != 1:
        return "Exactly one Android recovery record is required"
    try:
        value = json.loads((directory / names[0]).read_text())
        cases = value["cases"]
        if value["schemaVersion"] != 1 or len(cases) != 2 or {c["codec"] for c in cases} != {"H264", "H265"}:
            return "Recovery evidence must cover H.264 and HEVC exactly once"
        for case in cases:
            timestamp = case["protectedRtpTimestamp"]
            fault = case["fault"]
            if (type(timestamp) is not int or not 0 <= timestamp <= 0xffffffff
                    or case["decodedQuantizedRtpTimestamp"] != timestamp // 90 * 90
                    or fault["repairedTimestamp"] != timestamp or fault["mode"] != "proof-complete"
                    or not finite_number(fault["dropped"], 1) or not finite_number(fault["repair"], 1)):
                return "Recovery evidence lacks exact-frame FEC proof with original and repairs dropped"
            if (not case["decoder"] or not finite_number(case["nativeFramesDecoded"], 1)
                    or not finite_number(case["referenceRecoveries"], 1)
                    or case["presentationEndpoint"] not in (
                        "REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED",
                        "REMOTE_DESKTOP_RENDER_MEASUREMENT_EGL_SUBMITTED")
                    or not finite_number(case["postLossContinuityCheckMs"])
                    or not finite_number(case["fecProbeToObservedDecodeMs"])):
                return "Recovery evidence lacks actual decode/reference completion or a valid endpoint"
    except (OSError, ValueError, KeyError, TypeError):
        return "Malformed Android recovery evidence"
    return None


def compare(current, baseline):
    """No comparison across hosts, workloads, codecs, clocks or output endpoints."""
    if current["hardware"] != baseline["hardware"]:
        return {"status": "unavailable", "reason": "Hardware/OS identity differs"}
    old = {c["id"]: c for c in baseline["cases"]}
    differences = []
    for case in current["cases"]:
        prior = old.get(case["id"])
        if case["status"] != "passed" or prior is None or prior["status"] != "passed":
            differences.append({"id": case["id"], "status": "unavailable", "reason": "Both matching cases must pass"})
            continue
        now, before = case.get("metrics", {}), prior.get("metrics", {})
        identity = ("presentationEndpoint", "codec", "requestedFps", "width", "height")
        same_scene = all(case["scenario"].get(k) == prior["scenario"].get(k) for k in ("runner", "capture", "fps", "codec"))
        complete = all(
            bool(m.get("presentationEndpoint")) and bool(m.get("codec"))
            and all(finite_number(m.get(k), 1) for k in ("requestedFps", "width", "height"))
            and finite_number(m.get("inputP95Ms")) and finite_number(m.get("inputSamples"), 200)
            for m in (now, before))
        if not same_scene or not complete or any(now.get(k) != before.get(k) for k in identity):
            differences.append({"id": case["id"], "status": "unavailable", "reason": "Metric/scene identity differs or is missing"})
            continue
        motion = case["scenario"].get("capture", "synthetic") != "screen"
        if motion and not all(finite_number(m.get("achievedFps"), 1) for m in (now, before)):
            differences.append({"id": case["id"], "status": "unavailable", "reason": "Motion cases require measured cadence"})
            continue
        delta = now["inputP95Ms"] - before["inputP95Ms"]
        # An input-only static scene does not measure sustained cadence. Leave
        # that gate to its mandatory motion case rather than inventing 0 fps.
        cadence = now["achievedFps"] / max(1, before["achievedFps"]) if "achievedFps" in now and "achievedFps" in before else None
        differences.append({"id": case["id"], "status": "passed" if delta <= 5 and (cadence is None or cadence >= .95) else "failed",
                            "inputP95DeltaMs": delta, "cadenceRatio": cadence,
                            "reason": "Latency/cadence gate only; quality, wire bytes and optical qualification remain separate"})
    return {"status": "passed" if differences and all(c["status"] == "passed" for c in differences) else "failed", "cases": differences}


def run_case(case, serial, output):
    directory = output / case["id"]
    directory.mkdir()
    result = {"id": case["id"], "scenario": case, "status": "unavailable", "artifacts": []}
    if case["runner"] == "external":
        result["reason"] = case.get("reason", "External qualification evidence required")
        return result
    try:
        argv, settings = command(case, serial)
    except ValueError as error:
        result["reason"] = str(error)
        return result
    result.update(command=argv, environment=settings)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DIETER_SCREEN_", "DIETER_TEST_SCREEN_", "DIETER_TEST_CAPTURE_", "DIETER_TEST_RECOVERY_"))}
    env.update(settings)
    started = time.monotonic()
    with (directory / "run.log").open("w") as log:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=case.get("timeoutSeconds", 1800))
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Only this owned fixture process group; wrappers retain their EXIT cleanup.
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=30)
            except subprocess.TimeoutExpired:
                result["remainingOwnedProcessGroup"] = child.pid
            result.update(status="failed", reason="Fixture interrupted or exceeded its timeout")
            code = -1
    result["durationSeconds"] = round(time.monotonic() - started, 3)
    result["exitCode"] = code
    log = (directory / "run.log").read_text(errors="replace")
    try:
        result["artifacts"] = collect(log, directory)
        result["metrics"] = metrics(directory, result["artifacts"])
    except (OSError, ValueError, TypeError) as error:
        result.update(status="failed", reason="Could not read required evidence: " + str(error))
        return result
    recovery_error = recovery_evidence_error(directory, result["artifacts"]) if case["runner"] == "android-recovery" else None
    if code != 0:
        result.update(status="failed", reason=result.get("reason", "Fixture failed; see run.log"))
    elif case["runner"] == "mac-latency" and not result["metrics"]:
        result.update(status="failed", reason="Command succeeded without mandatory latency evidence")
    elif case["runner"] == "android-codec" and not any(a.endswith("decoder-H264.json") for a in result["artifacts"]):
        result.update(status="failed", reason="Missing actual decoder identity")
    elif case["runner"] == "android-sdk" and not any(a.endswith("-decoder-sdk.json") for a in result["artifacts"]):
        result.update(status="failed", reason="Missing actual codec/ownership/launcher test evidence")
    elif case["runner"] == "android-journey" and not any(a.endswith("-stats.json") for a in result["artifacts"]):
        result.update(status="failed", reason="Missing actual Android journey evidence")
    elif recovery_error:
        result.update(status="failed", reason=recovery_error)
    elif case["runner"] == "mac-recovery" and not complete_mac_recovery(log):
        result.update(status="failed", reason="Required eight-cell native recovery matrix/FEC proofs did not execute")
    elif case["runner"] == "native" and not re.search(r"^ok\s+github.com/dbpprt/dieter/internal/remotedesktop\s+\d", log, re.M):
        result.update(status="failed", reason="Native hardware package did not report an executed pass")
    elif case["runner"].startswith("android-") and not re.search(r"^[1-9][0-9]* requested, [1-9][0-9]* passed, 0 failed/unavailable;", log, re.M):
        result.update(status="failed", reason="Device tests did not report execution")
    elif case["runner"].startswith("mac-") and not re.search(r"✔ Test run with [1-9][0-9]* test", log):
        result.update(status="failed", reason="Native tests did not report an executed pass")
    else:
        result.update(status="passed", reason="Fixture assertions passed")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serial")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--case", action="append", dest="selected")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    assert manifest["schemaVersion"] == 1
    cases = manifest["cases"]
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)) and all(re.fullmatch(r"[a-z0-9-]+", i) for i in ids)
    assert not args.selected or set(args.selected) <= set(ids), "Unknown requested case"
    if args.selected:
        cases = [c for c in cases if c["id"] in args.selected]
    args.output.mkdir(parents=True, exist_ok=False)
    git = lambda *a: subprocess.check_output(["git", *a], cwd=ROOT).decode().strip()
    hardware = {"system": platform.platform(), "machine": platform.machine()}
    if platform.system() == "Darwin":
        hardware["model"] = subprocess.check_output(["sysctl", "-n", "hw.model"]).decode().strip()
    if args.serial:
        adb = str(Path(os.environ.get("ANDROID_HOME", str(Path.home() / "Library/Android/sdk"))) / "platform-tools/adb")
        hardware["androidSerial"] = args.serial
        for prop in ("ro.product.model", "ro.build.fingerprint"):
            hardware[prop] = subprocess.check_output([adb, "-s", args.serial, "shell", "getprop", prop]).decode().strip()
    record = {"schemaVersion": 1, "manifest": manifest["id"], "commit": git("rev-parse", "HEAD"),
              "trackedDiffSHA256": hashlib.sha256(git("diff", "HEAD").encode()).hexdigest(),
              "workingTree": git("status", "--porcelain"), "hardware": hardware, "cases": []}
    record["sourceSHA256"] = source_fingerprint()
    shutil.copyfile(args.manifest, args.output / "scenario.json")
    if args.baseline:
        shutil.copyfile(args.baseline, args.output / "baseline.json")
    for case in cases:
        print("Running " + case["id"], flush=True)
        record["cases"].append(run_case(case, args.serial, args.output))
        print(case["id"] + ": " + record["cases"][-1]["status"], flush=True)
        (args.output / "results.json").write_text(json.dumps(record, indent=2))
    if args.baseline:
        record["comparison"] = compare(record, json.loads(args.baseline.read_text()))
    required = set(manifest.get("required", ids))
    record["missingRequired"] = sorted(required - {c["id"] for c in record["cases"]})
    record["fixtureStatus"] = "passed" if not record["missingRequired"] and all(c["status"] == "passed" for c in record["cases"] if c["id"] in required) else "failed"
    record["finalSourceSHA256"] = source_fingerprint()
    record["sourceUnchangedDuringRun"] = record["sourceSHA256"] == record["finalSourceSHA256"]
    record["status"] = "passed" if record["fixtureStatus"] == "passed" and record.get("comparison", {}).get("status", "passed") == "passed" and record["sourceUnchangedDuringRun"] else "failed"
    (args.output / "results.json").write_text(json.dumps(record, indent=2))
    report = ["# Screen qualification: " + record["status"], "", "| Case | Result | Evidence/reason |", "|---|---|---|"]
    report += [f"| {c['id']} | {c['status']} | {c['reason']} |" for c in record["cases"]]
    report += ["", "Missing required: " + (", ".join(record["missingRequired"]) or "none"), "",
               "Source unchanged during run: " + str(record["sourceUnchangedDuringRun"]), "",
               "A fixture pass is not codec, bandwidth, power, thermal or optical qualification. No defaults are promoted by this runner."]
    if "comparison" in record:
        report += ["", "Baseline comparison: " + record["comparison"]["status"], "", "```json", json.dumps(record["comparison"], indent=2), "```"]
    (args.output / "report.md").write_text("\n".join(report) + "\n")
    return 0 if record["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
