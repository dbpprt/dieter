#!/usr/bin/env python3
"""Rebuild the narrow Java SDK extension; retain the verified native SDK unchanged."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as result:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            result.writestr(info, data)
    return output.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--aar", type=Path, required=True)
    parser.add_argument("--android-jar", type=Path, required=True)
    parser.add_argument("--annotation", type=Path, required=True)
    parser.add_argument("--javac", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = json.loads((ROOT / "upstream.json").read_text())
    original = args.aar.read_bytes()
    if sha(original) != pin["aarSHA256"]:
        raise SystemExit("Upstream WebRTC AAR differs from the audited SDK pin")
    with zipfile.ZipFile(io.BytesIO(original)) as aar:
        entries = {name: aar.read(name) for name in aar.namelist() if not name.endswith("/")}
    sources = sorted((ROOT / "java").rglob("*.java"))
    native = {name: sha(data) for name, data in entries.items() if name.startswith("jni/")}
    if len(native) != 4 or not all(name.endswith("/libjingle_peerconnection_so.so") for name in native):
        raise SystemExit("Unexpected native ABI/library set; audit the SDK before building")
    with tempfile.TemporaryDirectory(prefix="dieter-webrtc-java-") as tmp:
        tmp = Path(tmp)
        base = tmp / "classes.jar"
        base.write_bytes(entries["classes.jar"])
        output = tmp / "classes"
        output.mkdir()
        import os
        classpath = os.pathsep.join(map(str, (base, args.android_jar, args.annotation)))
        subprocess.run([str(args.javac), "--release", "8", "-Xlint:-options,-classfile", "-classpath", classpath,
                        "-d", str(output), *map(str, sources)], check=True)
        prefixes = {"org/webrtc/" + source.stem for source in sources}
        with zipfile.ZipFile(base) as jar:
            classes = {name: jar.read(name) for name in jar.namelist() if not name.endswith("/") and
                       not any(name == prefix + ".class" or name.startswith(prefix + "$") for prefix in prefixes)}
        for path in output.rglob("*.class"):
            classes[path.relative_to(output).as_posix()] = path.read_bytes()
        # Java resources survive application packaging; retain the derivative
        # source notices in the distributed binary as well as in the repository.
        classes["META-INF/LICENSE.dieter-webrtc"] = (b"Modifications copyright (c) 2026 Dieter contributors.\n\n" +
                                                    (ROOT / "LICENSE").read_bytes())
        classes["META-INF/PATENTS.dieter-webrtc"] = (ROOT / "PATENTS").read_bytes()
        entries["classes.jar"] = archive(classes)
    provenance = {"schemaVersion": 1, "upstream": pin, "nativeSHA256": native,
                  "javac": subprocess.check_output([str(args.javac), "-version"], text=True).strip(),
                  "sources": {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in sources},
                  "builderSHA256": sha(Path(__file__).read_bytes())}
    entries["META-INF/dieter-webrtc.json"] = json.dumps(provenance, sort_keys=True, indent=2).encode() + b"\n"
    result = archive(entries)
    with zipfile.ZipFile(io.BytesIO(result)) as aar:
        assert native == {name: sha(aar.read(name)) for name in native}, "Native SDK was modified"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(result)
    args.output.with_suffix(".json").write_text(json.dumps({**provenance, "aarSHA256": sha(result)}, indent=2) + "\n")
    print("Patched Java SDK; all four native ABI libraries unchanged. SHA-256 " + sha(result))


if __name__ == "__main__":
    main()
