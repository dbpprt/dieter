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
import tempfile
from common import ROOT, IMAGE, IDENTITY, ISSUER, NAME, atomic, digest, keys, read_json, require, run

ARCHIVE = "dieter-gateway-deploy.tar.gz"
MANIFEST = "gateway-manifest.json"
SIGNATURE = "gateway-manifest.sigstore.json"
REGISTRY = "ghcr.io/dbpprt/dieter-gateway-deploy"
IDENTITIES = (IDENTITY, "https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main")


def pack(output, revision, version, image, built_at, probes=None):
    require(re.fullmatch(r"[a-f0-9]{40}", revision), "source revision must be a full commit")
    require(NAME.fullmatch(version), "invalid release version")
    require(IMAGE.fullmatch(image), "image must be digest pinned")
    out = Path(output)
    out.mkdir(parents=True, exist_ok=True)
    archive = out / ARCHIVE
    require(not archive.exists(), "bundle already exists")
    with archive.open("wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as zipped:
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
    manifest = {"manifestVersion": 1, "bundleInterfaceVersion": 1, "releaseVersion": version,
                "sourceRevision": revision, "builtAt": built_at, "image": image,
                "platforms": ["linux/amd64", "linux/arm64"], "applicationContract": 1, "gatewayStoreSchema": 1,
                "bundle": {"name": ARCHIVE, "sha256": digest(archive)},
                "dependencies": read_json(ROOT / "dependencies.lock.json")}
    atomic(out / MANIFEST, json.dumps(manifest, indent=2) + "\n", 0o644)
    return manifest


def validate_manifest(m):
    keys(m, "manifestVersion bundleInterfaceVersion releaseVersion sourceRevision builtAt image platforms applicationContract gatewayStoreSchema bundle dependencies".split(), "manifest")
    require(all(type(m[key]) is int and m[key] == 1 for key in ("manifestVersion", "bundleInterfaceVersion", "applicationContract", "gatewayStoreSchema")),
            "incompatible manifest, application contract or store schema")
    require(NAME.fullmatch(m["releaseVersion"]) and re.fullmatch(r"[a-f0-9]{40}", m["sourceRevision"]), "invalid release identity")
    require(IMAGE.fullmatch(m["image"]) and m["image"].startswith("ghcr.io/dbpprt/dieter-gateway@"), "invalid gateway image")
    require(m["platforms"] == ["linux/amd64", "linux/arm64"], "both supported platforms are required")
    keys(m["bundle"], ("name", "sha256"), "bundle")
    require(m["bundle"]["name"] == ARCHIVE and re.fullmatch(r"[a-f0-9]{64}", m["bundle"]["sha256"]), "invalid bundle identity")
    keys(m["dependencies"], ("caddy", "coturn", "haproxy", "certbot", "restic"), "dependencies")
    require(all(IMAGE.fullmatch(v) for v in m["dependencies"].values()), "unpinned dependency")


def verify_signature(directory):
    directory = Path(directory)
    verified = False
    for identity in IDENTITIES:
        try:
            run(["cosign", "verify-blob", "--bundle", directory / SIGNATURE,
                 "--certificate-identity", identity, "--certificate-oidc-issuer", ISSUER, directory / MANIFEST])
            verified = True
            break
        except ValueError:
            pass
    require(verified, "manifest signature does not match an authorized main workflow")


def verify(directory, expected_revision=None, expected_image=None, image_signature=True):
    directory = Path(directory)
    verify_signature(directory)
    m = read_json(directory / MANIFEST)
    validate_manifest(m)
    require(digest(directory / ARCHIVE) == m["bundle"]["sha256"], "bundle checksum mismatch")
    require(expected_revision is None or expected_revision == m["sourceRevision"], "source revision mismatch")
    require(expected_image is None or expected_image == m["image"], "image digest mismatch")
    if image_signature:
        verified = False
        for identity in IDENTITIES:
            try:
                run(["cosign", "verify", "--certificate-identity", identity, "--certificate-oidc-issuer", ISSUER,
                     "-a", "sourceRevision=" + m["sourceRevision"], m["image"]], timeout=180)
                verified = True
                break
            except ValueError:
                pass
        require(verified, "image signature does not match the manifest source")
    return m


def extract(archive, output):
    out = Path(output)
    require(not out.exists(), "extraction destination exists")
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        require(len(members) <= 512 and sum(m.size for m in members) <= 32 * 1024 * 1024, "bundle exceeds extraction limits")
        seen = set()
        for m in members:
            p = Path(m.name)
            require(m.isfile() and not p.is_absolute() and ".." not in p.parts and p.as_posix() == m.name
                    and m.name not in seen, "unsafe bundle member")
            seen.add(m.name)
        out.mkdir(parents=True, mode=0o755)
        for m in members:
            atomic(out / m.name, tar.extractfile(m).read(), m.mode & 0o755)


def publish():
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_REF") == "refs/heads/main", "publishing requires CI on main")
    revision = os.environ["GITHUB_SHA"]
    source = run(["git", "rev-parse", "HEAD"]).decode().strip()
    require(source == revision, "publisher checkout does not match triggering commit")
    version = os.environ["GATEWAY_RELEASE_VERSION"]
    require(NAME.fullmatch(version), "invalid release version")
    built_at = run(["git", "show", "-s", "--format=%cI", "HEAD"]).decode().strip()
    image_tag = "ghcr.io/dbpprt/dieter-gateway:source-" + revision
    out = Path("dist")
    out.mkdir(exist_ok=True)
    run(["docker", "buildx", "build", "--file", "Dockerfile.gateway", "--platform", "linux/amd64,linux/arm64",
         "--push", "--provenance=mode=max", "--sbom=true", "--metadata-file", out / "gateway-build.json",
         "--build-arg", "RELEASE_VERSION=" + version, "--build-arg", "SOURCE_REVISION=" + revision,
         "--build-arg", "BUILT_AT=" + built_at, "--tag", image_tag, "--tag", "ghcr.io/dbpprt/dieter-gateway:" + version,
         "--label", "org.opencontainers.image.revision=" + revision, "."], timeout=3600, capture=False)
    image = "ghcr.io/dbpprt/dieter-gateway@" + read_json(out / "gateway-build.json")["containerimage.digest"]
    run(["oras", "tag", image, "digest-" + image.rsplit(":", 1)[1]], timeout=180)
    probes = {}
    for system, arch in (("linux", "amd64"), ("linux", "arm64"), ("darwin", "arm64")):
        name = f"gateway-turn-probe-{system}-{arch}"
        path = out / name
        run(["env", "CGO_ENABLED=0", "GOOS=" + system, "GOARCH=" + arch, "go", "build", "-trimpath",
             "-ldflags=-s -w", "-o", path, "./scripts/gateway-turn-probe"], timeout=300)
        probes[name] = path
    pack(out, revision, version, image, built_at, probes)
    run(["cosign", "sign", "--yes", "-a", "sourceRevision=" + revision, image], timeout=300, capture=False)
    run(["cosign", "sign-blob", "--yes", "--bundle", out / SIGNATURE, out / MANIFEST], timeout=300, capture=False)
    verify(out, revision, image)
    # The durable OCI artifact is independent of GitHub release pruning. Neither
    # repository's workflows delete these tags. Backups also retain pulled images.
    # ORAS paths must be relative to the artifact directory to prevent embedding dist/.
    previous = Path.cwd()
    try:
        os.chdir(out)
        run(["oras", "push", REGISTRY + ":" + version, "--artifact-type", "application/vnd.dieter.gateway.deployment.v1",
             "--annotation", "org.opencontainers.image.revision=" + revision,
             ARCHIVE + ":application/gzip", MANIFEST + ":application/json", SIGNATURE + ":application/json"], timeout=300, capture=False)
        descriptor = json.loads(run(["oras", "manifest", "fetch", "--descriptor", REGISTRY + ":" + version]))
    finally:
        os.chdir(previous)
    run(["oras", "tag", REGISTRY + "@" + descriptor["digest"], "digest-" + descriptor["digest"].split(":")[1]], timeout=180)
    atomic(out / "gateway-release.lock.json", json.dumps({"interfaceVersion": 1, "artifact": REGISTRY + "@" + descriptor["digest"],
           "releaseVersion": version, "sourceRevision": revision, "image": image, "bundleSHA256": digest(out / ARCHIVE)}, indent=2) + "\n", 0o644)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    make = sub.add_parser("pack")
    for name in ("output", "revision", "version", "image", "built-at"):
        make.add_argument("--" + name, required=True)
    check = sub.add_parser("verify")
    check.add_argument("directory")
    check.add_argument("--revision")
    check.add_argument("--image")
    fetch = sub.add_parser("fetch")
    fetch.add_argument("lock")
    fetch.add_argument("output")
    sub.add_parser("publish")
    a = p.parse_args()
    if a.command == "pack":
        pack(a.output, a.revision, a.version, a.image, a.built_at)
    elif a.command == "verify":
        verify(a.directory, a.revision, a.image)
    elif a.command == "fetch":
        lock = read_json(a.lock)
        require(lock["interfaceVersion"] == 1 and IMAGE.fullmatch(lock["artifact"])
                and lock["artifact"].startswith(REGISTRY + "@"), "invalid release lock")
        require(not Path(a.output).exists(), "fetch destination already exists")
        Path(a.output).mkdir(parents=True)
        run(["oras", "pull", lock["artifact"], "--output", a.output], timeout=300)
        m = verify(a.output, lock["sourceRevision"], lock["image"])
        require(m["releaseVersion"] == lock["releaseVersion"] and m["bundle"]["sha256"] == lock["bundleSHA256"], "lock mismatch")
        extract(Path(a.output) / ARCHIVE, Path(a.output) / "bundle")
    elif a.command == "publish":
        publish()


if __name__ == "__main__":
    main()
