"""Expose only the development-signed E2E app's owned media through Files."""

import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile


def configure(path, configuration, bundle_id):
    if configuration != "Debug" or not bundle_id.endswith(".e2e"):
        return
    path = Path(path)
    info = plistlib.loads(path.read_bytes())
    if info.get("CFBundleIdentifier") != bundle_id:
        raise ValueError("E2E media bundle identity mismatch")
    info.update(CFBundleDisplayName="Dieter E2E", UIFileSharingEnabled=True,
                LSSupportsOpeningDocumentsInPlace=True)
    fd, temporary = tempfile.mkstemp(prefix=".e2e-info-", dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
        with os.fdopen(fd, "wb") as stream:
            plistlib.dump(info, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    configure(*sys.argv[1:])
