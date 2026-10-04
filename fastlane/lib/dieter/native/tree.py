#!/usr/bin/env python3
"""Hold a canonical native-build resource lock across exec; never wait silently."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile


def tree_digest(path):
    """Compare framework bytes and link targets without following framework loops."""
    result = hashlib.sha256()
    for directory, dirs, files in os.walk(path, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            entry = Path(directory) / name
            result.update(str(entry.relative_to(path)).encode() + b"\0")
            if entry.is_symlink():
                result.update(b"link\0" + os.readlink(entry).encode() + b"\0")
            elif entry.is_file():
                result.update(b"file\0" + str(entry.stat().st_mode & 0o777).encode() + b"\0")
                # XCFramework library ordering/serialization is packaging metadata,
                # not a change to any slice. Preserve a valid existing publication.
                if entry.relative_to(path).as_posix() == "Info.plist":
                    try:
                        metadata = plistlib.loads(entry.read_bytes())
                        libraries = metadata.get("AvailableLibraries")
                        if isinstance(libraries, list):
                            metadata["AvailableLibraries"] = sorted(libraries, key=lambda item: item["LibraryIdentifier"])
                        result.update(plistlib.dumps(metadata, sort_keys=True))
                        continue
                    except (ValueError, TypeError, KeyError, AttributeError, plistlib.InvalidFileException):
                        pass
                with entry.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        result.update(block)
            else:
                result.update(b"directory\0")
    return result.digest()
