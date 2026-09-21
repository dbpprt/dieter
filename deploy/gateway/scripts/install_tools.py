#!/usr/bin/env python3
"""Install verified bootstrap tools without upgrading the OS or Docker daemon."""
import argparse
import bz2
import hashlib
import io
from pathlib import Path
import platform
import tarfile
import time
import urllib.error
import urllib.request
from common import ROOT, atomic, read_json, require


def install(name, destination):
    arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
    system = platform.system().lower()
    entry = read_json(ROOT / "tools.lock.json")[name][system + "/" + arch]
    require(entry["url"].startswith("https://github.com/"), "unexpected tool download origin")
    destination = Path(destination)
    receipt = destination.with_name(destination.name + ".sha256.json")
    if destination.is_file() and receipt.is_file():
        cached = read_json(receipt)
        with destination.open("rb") as binary:
            checksum = hashlib.file_digest(binary, "sha256").hexdigest()
        if cached == {"artifactSHA256": entry["sha256"], "binarySHA256": checksum}:
            return
    for attempt in range(4):
        try:
            with urllib.request.urlopen(entry["url"], timeout=60) as response:
                data = response.read(256 * 1024 * 1024 + 1)
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)
    require(len(data) <= 256 * 1024 * 1024 and hashlib.sha256(data).hexdigest() == entry["sha256"], "tool checksum mismatch")
    member = entry.get("archiveMember")
    if member:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            target = archive.getmember(member)
            require(target.isfile() and target.size <= 256 * 1024 * 1024, "unsafe tool archive")
            data = archive.extractfile(target).read()
    elif entry["url"].endswith(".bz2"):
        data = bz2.decompress(data)
    atomic(destination, data, 0o755)
    import json
    atomic(receipt, json.dumps({"artifactSHA256": entry["sha256"], "binarySHA256": hashlib.sha256(data).hexdigest()}))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("name")
    p.add_argument("destination")
    a = p.parse_args()
    install(a.name, Path(a.destination))
