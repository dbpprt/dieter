"""Small, dependency-free primitives shared by the signed gateway bundle."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = "https://github.com/dbpprt/dieter/.github/workflows/gateway-image.yml@refs/heads/main"
ISSUER = "https://token.actions.githubusercontent.com"
IMAGE = re.compile(r"[a-z0-9./_-]+@sha256:[a-f0-9]{64}\Z")
NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}\Z")
_log_path = None


def set_operation_log(path):
    global _log_path
    _log_path = Path(path)


def protected_log(data):
    if _log_path is None:
        return
    # Bound each operation's diagnostic file, including errors from dependencies
    # which may echo secret-bearing configuration. It is never returned by SSH.
    if _log_path.exists() and _log_path.stat().st_size > 1024*1024:
        os.replace(_log_path, _log_path.with_suffix(".previous.log"))
    fd = os.open(_log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "ab") as stream:
        stream.write(data[-32768:] + b"\n")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs)


def validate_gateway_health(health, manifest=None):
    require(health.get("service") == "dieter-gateway" and health.get("status") == "ok", "gateway is not healthy")
    contract = health.get("apiVersion")
    require(isinstance(contract, str) and re.fullmatch(r"[1-9][0-9]*", contract), "gateway contract is missing or invalid")
    if manifest is not None:
        require(type(manifest.get("applicationContract")) is int and manifest["applicationContract"] > 0,
                "release application contract is missing or invalid")
        require(contract == str(manifest["applicationContract"]), "gateway contract differs from signed release")
        require(health.get("revision") == manifest["sourceRevision"], "unexpected live source revision")


def keys(value, expected, label):
    require(isinstance(value, dict) and set(value) == set(expected), f"invalid {label} fields")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def atomic(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".pending-")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data.encode() if isinstance(data, str) else data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def pointer(path, target):
    path = Path(path)
    temporary = path.with_name(path.name + ".pending")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    os.replace(temporary, path)
    sync_dir(path.parent)


def run(argv, *, timeout=120, input=None, capture=True):
    # Never include argv, stdout or stderr in errors: external tools may echo
    # private configuration. A protected operation log can be inspected locally.
    result = subprocess.run([str(a) for a in argv], input=input, capture_output=capture,
                            timeout=timeout, check=False)
    if result.returncode and capture:
        protected_log(Path(argv[0]).name.encode() + b": " + (result.stderr or b""))
    require(result.returncode == 0, f"{Path(argv[0]).name} failed (exit {result.returncode})")
    return result.stdout if capture else b""
