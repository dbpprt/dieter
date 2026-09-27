#!/usr/bin/env python3
"""Stage, validate and atomically activate the canonical, stopped Mac application."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def entries(root: Path, products: Path) -> list[tuple[Path, str]]:
    resources = root / "apps/mac/Resources"
    return [
        (resources / "Info.plist", "Contents/Info.plist"),
        (resources / "DieterMonochrome.icns", "Contents/Resources/Dieter.icns"),
        (resources / "PaletteIcons/monochrome.png", "Contents/Resources/DieterAppIcon.png"),
        (resources / "DieterMonochromeFavicon.png", "Contents/Resources/DieterFavicon.png"),
        (resources / "PaletteIcons", "Contents/Resources/PaletteIcons"),
        (root / "assets/brand/assets/fonts/Sora-Variable.ttf", "Contents/Resources/Fonts/Sora-Variable.ttf"),
        (products / "DieterMac", "Contents/MacOS/DieterMac"),
        (products / "WebRTC.framework", "Contents/Frameworks/WebRTC.framework"),
        (products / "DieterMac_DieterMac.bundle", "Contents/Resources/DieterMac_DieterMac.bundle"),
        (products / "Highlighter_Highlighter.bundle", "Contents/Resources/Highlighter_Highlighter.bundle"),
    ]


def inventory(path: Path) -> list[dict]:
    """Content and executable modes, including link identities and removed files; no shell path splitting."""
    result = []
    for item in [path, *sorted(path.rglob("*"))] if path.is_dir() and not path.is_symlink() else [path]:
        stat = item.lstat()
        record = {"path": str(item.relative_to(path)), "mode": stat.st_mode & 0o777}
        if item.is_symlink():
            # The framework's version links are preserved, but cannot escape the copied tree.
            if not item.resolve(strict=True).is_relative_to(path.resolve()):
                raise ValueError(f"Bundle input symlink escapes its tree: {item}")
            record["link"] = os.readlink(item)
        elif item.is_file():
            with item.open("rb") as source:
                record["sha256"] = hashlib.file_digest(source, "sha256").hexdigest()
        elif not item.is_dir():
            raise ValueError(f"Unsupported bundle input: {item}")
        result.append(record)
    return result


def signing_identity(environment: dict[str, str]) -> str:
    explicit = environment.get("DIETER_MAC_SIGNING_IDENTITY")
    if explicit:
        return explicit
    if environment.get("CI") != "true":
        result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], check=True, text=True, capture_output=True)
        identities = re.findall(r'\) ([0-9A-F]+) "Apple Development:', result.stdout)
        if len(identities) == 1:
            return identities[0]
    return "-"


def exchange(stage: Path, bundle: Path) -> None:
    """Exchange complete trees in one filesystem operation; interruption always leaves a complete app."""
    if not bundle.exists():
        os.replace(stage, bundle)
        return
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        result = libc.renamex_np(os.fsencode(stage), os.fsencode(bundle), 2)  # RENAME_SWAP
    elif sys.platform.startswith("linux"):
        result = libc.renameat2(-100, os.fsencode(stage), -100, os.fsencode(bundle), 2)  # RENAME_EXCHANGE
    else:
        raise RuntimeError("Atomic bundle exchange is unavailable on this platform")
    if result:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def package(root: Path, products: Path, identity: str, version: str = "", *, run=subprocess.run) -> Path:
    output = root / "apps/mac/build"
    bundle = output / "Dieter.app"
    manifest = output / ".Dieter.bundle.json"
    sources = entries(root, products)
    inputs = {
        "entries": [{"destination": target, "source": str(source), "tree": inventory(source)} for source, target in sources],
        "implementation": {str(path.relative_to(root)): inventory(path) for path in [
            root / "scripts/mac_bundle.py", root / "apps/mac/scripts/build.sh", root / "apps/mac/scripts/verify-bundle.sh",
        ]},
        "version": version, "signingIdentity": identity,
    }
    guard = [sys.executable, str(root / "scripts/mac_app_lifecycle.py"), "assert-stopped"]
    verify = [str(root / "apps/mac/scripts/verify-bundle.sh")]
    run(guard, check=True)
    try:
        previous = json.loads(manifest.read_text())
        unchanged = previous["inputs"] == inputs and previous["outputs"] == inventory(bundle)
    except (OSError, ValueError, KeyError):
        unchanged = False
    if unchanged:
        run([*verify, str(bundle)], check=True)
        print("Bundle inputs and signed outputs unchanged", file=sys.stderr)
        return bundle
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".Dieter.stage-", dir=output) as temporary:
        stage = Path(temporary) / "Dieter.app"
        for source, target in sources:
            destination = stage / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, destination, symlinks=True)
            else:
                shutil.copy2(source, destination)
        if version:
            plist = stage / "Contents/Info.plist"
            value = plistlib.loads(plist.read_bytes())
            value["DieterReleaseVersion"] = version
            plist.write_bytes(plistlib.dumps(value))
        run(["codesign", "--force", "--sign", identity, str(stage / "Contents/Frameworks/WebRTC.framework")], check=True)
        run(["codesign", "--force", "--deep", "--sign", identity, str(stage)], check=True)
        run([*verify, str(stage)], check=True)
        staged_outputs = inventory(stage)
        # Inputs can change during an incremental build or while the staging copy is in progress.
        if any(entry["tree"] != inventory(source) for entry, (source, _) in zip(inputs["entries"], sources)):
            raise RuntimeError("Bundle inputs changed while staging; retry after the current build finishes")
        run(guard, check=True)
        exchange(stage, bundle)
        next_manifest = Path(temporary) / "manifest.json"
        next_manifest.write_text(json.dumps({"inputs": inputs, "outputs": staged_outputs}, sort_keys=True) + "\n")
        os.replace(next_manifest, manifest)
    return bundle


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    print(package(root, args.products, signing_identity(dict(os.environ)), os.environ.get("DIETER_RELEASE_VERSION", "")))


if __name__ == "__main__":
    main()
