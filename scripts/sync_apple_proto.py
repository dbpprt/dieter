#!/usr/bin/env python3
"""The single authoritative-schema to Apple-package copy transform."""
import argparse
import os
from pathlib import Path
import tempfile

SCHEMAS = {"dieter/v1/dieter.proto": "dieter.proto", "dieter/gateway/v1/gateway.proto": "gateway.proto"}


def schema_bytes(source: Path) -> bytes:
    return source.read_bytes().replace(b'import "dieter/gateway/v1/gateway.proto";', b'import "gateway.proto";')


def sync(root: Path, check: bool = False) -> bool:
    current = True
    for source, name in SCHEMAS.items():
        target = root / "apps/mac/Sources/DieterAPI" / name
        expected = schema_bytes(root / "api/proto" / source)
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
