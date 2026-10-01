#!/usr/bin/env python3
"""The single authoritative-schema to Apple-package copy transform."""
import argparse
import os
from pathlib import Path
import tempfile

SCHEMAS = {"dieter/v1/dieter.proto": "dieter.proto", "dieter/gateway/v1/gateway.proto": "gateway.proto"}
# The shared core's UI contract: it never crosses the network, so it lives with
# the core rather than in api/proto. Copied to Sources/DieterAPI/client/.
CLIENT_SCHEMA_DIR = "apps/core/model/src/commonMain/proto/dieter/client/v1"
CLIENT_TARGET_DIR = "client"


def schema_bytes(source: Path) -> bytes:
    return (
        source.read_bytes()
        .replace(b'import "dieter/gateway/v1/gateway.proto";', b'import "gateway.proto";')
        .replace(b'import "dieter/v1/dieter.proto";', b'import "dieter.proto";')
        .replace(b'import "dieter/client/v1/', b'import "client/')
    )


def schema_copies(root: Path) -> dict[Path, Path]:
    """Authoritative source -> Apple package copy, for every synced schema."""
    api = root / "apps/mac/Sources/DieterAPI"
    copies = {root / "api/proto" / source: api / name for source, name in SCHEMAS.items()}
    client = root / CLIENT_SCHEMA_DIR
    if client.is_dir():
        for source in sorted(client.glob("*.proto")):
            copies[source] = api / CLIENT_TARGET_DIR / source.name
    return copies


def sync(root: Path, check: bool = False) -> bool:
    current = True
    copies = schema_copies(root)
    # A client schema removed from the core leaves no stale copy behind.
    client_copies = root / "apps/mac/Sources/DieterAPI" / CLIENT_TARGET_DIR
    if client_copies.is_dir():
        expected_targets = set(copies.values())
        for stale in sorted(client_copies.glob("*.proto")):
            if stale in expected_targets:
                continue
            current = False
            if not check:
                stale.unlink()
                print(f"Removed {stale.name}")
    for source, target in copies.items():
        name = target.relative_to(root / "apps/mac/Sources/DieterAPI")
        expected = schema_bytes(source)
        if target.exists() and target.read_bytes() == expected:
            continue
        current = False
        if check:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
            path = Path(temporary.name)
            try:
                temporary.write(expected)
                temporary.flush()
                os.chmod(path, 0o644)
                os.replace(path, target)
            finally:
                path.unlink(missing_ok=True)
        print(f"Synced {name}")
    return current


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    current = sync(Path(__file__).resolve().parent.parent, arguments.check)
    raise SystemExit(1 if arguments.check and not current else 0)
