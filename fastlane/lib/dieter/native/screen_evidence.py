"""Pure screen measurement/recovery/comparison validation. No builds or devices."""
import json
import math
from pathlib import Path
import re
import shutil
import sys

EVIDENCE = re.compile(r"(?:Native screen|HEVC transport|Codec integration|Screen integration|Recovery integration|Decoder SDK|E2E) evidence: (/.+)")
ALLOWED_ARTIFACT = re.compile(r"(?:latency|input-latency|render-trace|stats|mac-stats|decoder-H26[45]|decoder-sdk|recovery)\.json|(?:viewer|hevc|recovery-H26[45]|canvas-(?:fit|pan|pinch))\.png")

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


def qualify(request):
    directory = Path(request["directory"])
    log = "\n".join(p.read_text(errors="replace") for p in directory.rglob("*.log") if not p.is_symlink() and p.stat().st_size <= 4 << 20)
    artifacts = collect(log, directory)
    # Android's pipeline already retains allowlisted measurements under its case.
    for index, path in enumerate(sorted(directory.rglob("*"))):
        if (path.parent == directory or not path.is_file() or path.is_symlink()
                or not ALLOWED_ARTIFACT.fullmatch(path.name) or path.stat().st_size > 16 << 20):
            continue
        target = directory / f"native-{index}-{path.name}"
        shutil.copyfile(path, target)
        artifacts.append(target.name)
    runner = request["runner"]
    measured = metrics(directory, artifacts)
    error = None
    if runner == "mac-latency" and not measured:
        error = "Missing mandatory latency evidence"
    elif runner == "android-codec" and not any(a.endswith("decoder-H264.json") for a in artifacts):
        error = "Missing actual decoder identity"
    elif runner == "android-sdk" and not any(a.endswith("-decoder-sdk.json") for a in artifacts):
        error = "Missing actual codec/ownership/launcher evidence"
    elif runner == "android-journey" and not any(a.endswith("-stats.json") for a in artifacts):
        error = "Missing actual Android journey evidence"
    elif runner == "android-recovery":
        error = recovery_evidence_error(directory, artifacts)
    elif runner == "mac-recovery" and not complete_mac_recovery(log):
        error = "Missing eight-cell recovery matrix and exact-frame FEC proofs"
    elif runner == "native" and not re.search(r"^ok\s+github.com/dbpprt/dieter/internal/remotedesktop\s+\d", log, re.M):
        error = "Native hardware package did not report an executed pass"
    if runner.startswith("mac-") and not re.search(r"✔ Test run with [1-9][0-9]* test", log):
        error = "Native tests did not report an executed pass"
    if runner.startswith("android-"):
        report = json.loads((directory / "results.json").read_text())
        if not report["results"] or any(r["status"] != "passed" for r in report["results"]):
            error = "Device tests did not report required execution"
    return {"artifacts": artifacts, "metrics": measured, "reason": error or "Fixture assertions passed", "status": "failed" if error else "passed"}


if __name__ == "__main__":
    request = json.load(sys.stdin)
    result = compare(request["current"], request["baseline"]) if request.get("operation") == "compare" else qualify(request)
    print(json.dumps(result, allow_nan=False))
