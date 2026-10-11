#!/usr/bin/env python3
"""Build, sign, verify and retrieve immutable deployment releases."""

import argparse
import gzip
import io
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import time
import subprocess
from common import (
    ROOT,
    IMAGE,
    IDENTITY,
    ISSUER,
    NAME,
    atomic,
    digest,
    keys,
    read_json,
    require,
    run,
    semantic_version,
    validate_compatibility_policy,
)
from identity import DEPLOYMENT_ARTIFACT, GATEWAY_IMAGE

ARCHIVE = "dieter-gateway-deploy.tar.gz"
MANIFEST = "gateway-manifest.json"
SIGNATURE = "gateway-manifest.sigstore.json"
LOCK = "gateway-release.lock.json"
REGISTRY = DEPLOYMENT_ARTIFACT


def publish_retry(argv, **options):
    """Retry only idempotent artifact/signature publication, never activation."""
    for attempt in range(4):
        try:
            return run(argv, **options)
        except (ValueError, subprocess.TimeoutExpired):
            if attempt == 3:
                raise
            time.sleep(2**attempt)


def pack(output, revision, version, image, built_at, probes=None):
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source revision must be a full commit")
    version = semantic_version(version)
    require(IMAGE.fullmatch(image), "image must be digest pinned")
    policy = validate_compatibility_policy(read_json(ROOT / "compatibility-policy.json"), version)
    out = Path(output)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / ARCHIVE
    require(not archive.exists(), "bundle already exists")
    with (
        archive.open("wb") as raw,
        gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as zipped,
    ):
        with tarfile.open(fileobj=zipped, mode="w") as tar:
            for path in sorted(ROOT.rglob("*")):
                if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
                    continue
                require(not path.is_symlink(), "bundle cannot contain symlinks")
                info = tarfile.TarInfo(path.relative_to(ROOT).as_posix())
                data = path.read_bytes()
                info.size = len(data)
                info.mode = 0o755 if path.suffix == ".py" else 0o644
                tar.addfile(info, io.BytesIO(data))
            for name, path in sorted((probes or {}).items()):
                info = tarfile.TarInfo("bin/" + name)
                data = Path(path).read_bytes()
                info.size = len(data)
                info.mode = 0o755
                tar.addfile(info, io.BytesIO(data))
    manifest = {
        "manifestVersion": 1,
        "bundleInterfaceVersion": 1,
        "releaseVersion": version,
        "sourceRevision": revision,
        "builtAt": built_at,
        "image": image,
        "platforms": ["linux/amd64", "linux/arm64"],
        "compatibilityPolicy": policy,
        "gatewayStoreSchema": 1,
        "bundle": {"name": ARCHIVE, "sha256": digest(archive)},
        "dependencies": read_json(ROOT / "dependencies.lock.json"),
    }
    atomic(out / MANIFEST, json.dumps(manifest, indent=2) + "\n", 0o644)
    atomic(out / (ARCHIVE + ".version"), version + "\n", 0o644)
    return manifest


def validate_manifest(m):
    keys(
        m,
        "manifestVersion bundleInterfaceVersion releaseVersion sourceRevision builtAt image platforms compatibilityPolicy gatewayStoreSchema bundle dependencies".split(),
        "manifest",
    )
    require(
        all(
            type(m[key]) is int and m[key] == 1
            for key in ("manifestVersion", "bundleInterfaceVersion", "gatewayStoreSchema")
        ),
        "incompatible manifest, bundle interface or store schema",
    )
    semantic_version(m["releaseVersion"])
    validate_compatibility_policy(m["compatibilityPolicy"], m["releaseVersion"])
    require(re.fullmatch(r"[a-f0-9]{40}", m["sourceRevision"]), "invalid release identity")
    require(
        IMAGE.fullmatch(m["image"]) and m["image"].startswith(GATEWAY_IMAGE + "@"),
        "invalid gateway image",
    )
    require(
        m["platforms"] == ["linux/amd64", "linux/arm64"], "both supported platforms are required"
    )
    keys(m["bundle"], ("name", "sha256"), "bundle")
    require(
        m["bundle"]["name"] == ARCHIVE and re.fullmatch(r"[a-f0-9]{64}", m["bundle"]["sha256"]),
        "invalid bundle identity",
    )
    keys(m["dependencies"], ("caddy", "coturn", "haproxy", "certbot", "restic"), "dependencies")
    require(all(IMAGE.fullmatch(v) for v in m["dependencies"].values()), "unpinned dependency")


def verify_signature(directory):
    directory = Path(directory)
    try:
        run(
            [
                "cosign",
                "verify-blob",
                "--bundle",
                directory / SIGNATURE,
                "--certificate-identity",
                IDENTITY,
                "--certificate-oidc-issuer",
                ISSUER,
                directory / MANIFEST,
            ]
        )
    except ValueError:
        raise ValueError("manifest signature does not match the release workflow") from None


def verify(directory, expected_revision=None, expected_image=None, image_signature=True):
    directory = Path(directory)
    verify_signature(directory)
    m = read_json(directory / MANIFEST)
    validate_manifest(m)
    require(digest(directory / ARCHIVE) == m["bundle"]["sha256"], "bundle checksum mismatch")
    require(
        expected_revision is None or expected_revision == m["sourceRevision"],
        "source revision mismatch",
    )
    require(expected_image is None or expected_image == m["image"], "image digest mismatch")
    if image_signature:
        try:
            run(
                [
                    "cosign",
                    "verify",
                    "--certificate-identity",
                    IDENTITY,
                    "--certificate-oidc-issuer",
                    ISSUER,
                    "-a",
                    "sourceRevision=" + m["sourceRevision"],
                    m["image"],
                ],
                timeout=180,
            )
        except ValueError:
            raise ValueError("image signature does not match the manifest source") from None
    return m


def extract(archive, output):
    out = Path(output)
    require(not out.exists(), "extraction destination exists")
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        require(
            len(members) <= 512 and sum(m.size for m in members) <= 32 * 1024 * 1024,
            "bundle exceeds extraction limits",
        )
        seen = set()
        for m in members:
            p = Path(m.name)
            require(
                m.isfile()
                and not p.is_absolute()
                and ".." not in p.parts
                and p.as_posix() == m.name
                and m.name not in seen,
                "unsafe bundle member",
            )
            seen.add(m.name)
        out.mkdir(parents=True, mode=0o755)
        for m in members:
            atomic(out / m.name, tar.extractfile(m).read(), m.mode & 0o755)


def push(directory, revision, version):
    """Publish a signed, verified bundle as an OCI artifact and write its lock.

    The release workflow builds and signs the image and the manifest first; this
    step only pushes the exact verified bytes and records their digests.
    """
    out = Path(directory)
    m = verify(out, revision)
    version = semantic_version(version)
    require(m["releaseVersion"] == version, "bundle version differs from the release")
    # ORAS paths must be relative to the artifact directory to keep layer titles portable.
    names = [
        ARCHIVE + ":application/gzip",
        MANIFEST + ":application/json",
        SIGNATURE + ":application/json",
    ]
    publish_retry(
        [
            "oras",
            "push",
            REGISTRY + ":" + version,
            "--artifact-type",
            "application/vnd.dieter.gateway.deployment.v1",
            "--annotation",
            "org.opencontainers.image.revision=" + revision,
            *names,
        ],
        timeout=300,
        capture=False,
        cwd=out,
    )
    descriptor = json.loads(
        run(["oras", "manifest", "fetch", "--descriptor", REGISTRY + ":" + version])
    )
    require(
        IMAGE.fullmatch(REGISTRY + "@" + descriptor["digest"]), "invalid deployment artifact digest"
    )
    atomic(
        out / LOCK,
        json.dumps(
            {
                "interfaceVersion": 1,
                "artifact": REGISTRY + "@" + descriptor["digest"],
                "releaseVersion": version,
                "sourceRevision": revision,
                "image": m["image"],
                "bundleSHA256": digest(out / ARCHIVE),
            },
            indent=2,
        )
        + "\n",
        0o644,
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    make = sub.add_parser("pack")
    for name in ("output", "revision", "version", "image", "built-at"):
        make.add_argument("--" + name, required=True)
    make.add_argument(
        "--probe",
        action="append",
        default=[],
        metavar="PATH",
        help="a TURN probe binary to ship under bin/ (repeatable)",
    )
    check = sub.add_parser("verify")
    check.add_argument("directory")
    check.add_argument("--revision")
    check.add_argument("--image")
    fetch = sub.add_parser("fetch")
    fetch.add_argument("lock")
    fetch.add_argument("output")
    publish = sub.add_parser("push")
    publish.add_argument("directory")
    publish.add_argument("--revision", required=True)
    publish.add_argument("--version", required=True)
    a = p.parse_args()
    if a.command == "pack":
        pack(
            a.output, a.revision, a.version, a.image, a.built_at, {Path(p).name: p for p in a.probe}
        )
    elif a.command == "verify":
        verify(a.directory, a.revision, a.image)
    elif a.command == "fetch":
        lock = read_json(a.lock)
        require(
            lock["interfaceVersion"] == 1
            and IMAGE.fullmatch(lock["artifact"])
            and lock["artifact"].startswith(REGISTRY + "@"),
            "invalid release lock",
        )
        require(not Path(a.output).exists(), "fetch destination already exists")
        Path(a.output).mkdir(parents=True)
        run(["oras", "pull", lock["artifact"], "--output", a.output], timeout=300)
        m = verify(a.output, lock["sourceRevision"], lock["image"])
        require(
            m["releaseVersion"] == lock["releaseVersion"]
            and m["bundle"]["sha256"] == lock["bundleSHA256"],
            "lock mismatch",
        )
        extract(Path(a.output) / ARCHIVE, Path(a.output) / "bundle")
    elif a.command == "push":
        push(a.directory, a.revision, a.version)


if __name__ == "__main__":
    main()
