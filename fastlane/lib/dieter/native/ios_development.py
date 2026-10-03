"""Validate existing local development profiles without registering Apple resources."""
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def select(profiles, identities, *, team, device, app, share, group, now=None):
    now = now or datetime.now(timezone.utc)
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Configure the existing ten-character development team")
    for identity in sorted(set(identities)):
        selected = {}
        for name, bundle in (("app", app), ("share", share), ("runner", app + ".uitests.xctrunner")):
            options = []
            for profile in profiles:
                entitlements = profile.get("Entitlements", {})
                expiry = profile.get("ExpirationDate")
                creation = profile.get("CreationDate")
                if not isinstance(expiry, datetime) or not isinstance(creation, datetime):
                    continue
                expiry = expiry.replace(tzinfo=timezone.utc)
                creation = creation.replace(tzinfo=timezone.utc)
                certificates = {hashlib.sha1(value).hexdigest().upper() for value in profile.get("DeveloperCertificates", [])}
                if (profile.get("TeamIdentifier") != [team] or device not in profile.get("ProvisionedDevices", [])
                        or entitlements.get("get-task-allow") is not True or expiry <= now or creation > now or creation >= expiry
                        or not fnmatch.fnmatchcase(team + "." + bundle, entitlements.get("application-identifier", ""))
                        or (name != "runner" and group not in entitlements.get("com.apple.security.application-groups", []))
                        or identity not in certificates):
                    continue
                uuid = profile.get("UUID", "")
                if re.fullmatch(r"[0-9A-Fa-f-]{36}", uuid):
                    options.append((expiry, uuid))
            if not options:
                break
            selected[name] = max(options)[1]
        if len(selected) == 3:
            return dict(selected, certificate=identity)
    raise ValueError("No existing development profiles cover the exact app, Share, test-runner identities, device, app group and a common local private key")


def inventory():
    roots = (Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
             Path.home() / "Library/MobileDevice/Provisioning Profiles")
    profiles = []
    for path in sorted({path for root in roots for path in root.glob("*.mobileprovision")}):
        if path.is_symlink() or not 0 < path.stat().st_size <= 2 * 1024 * 1024:
            continue
        result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, timeout=15)
        if result.returncode == 0:
            try:
                profiles.append(plistlib.loads(result.stdout))
            except (ValueError, plistlib.InvalidFileException):
                pass
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, timeout=15, check=True)
    identities = re.findall(r'([0-9A-F]{40}) "Apple Development:', result.stdout.decode())
    return profiles, identities


if __name__ == "__main__":
    request = json.load(sys.stdin)
    try:
        print(json.dumps(select(*inventory(), **request)))
    except (ValueError, subprocess.SubprocessError) as error:
        sys.exit("Development signing unavailable: " + str(error))
