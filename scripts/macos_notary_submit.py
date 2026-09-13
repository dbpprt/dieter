#!/usr/bin/env python3
"""Submit an Apple notarization archive and require an Accepted response."""

import argparse
import json
import subprocess
import sys


def submit(artifact, key, key_id, issuer):
    result = subprocess.run(
        ["xcrun", "notarytool", "submit", str(artifact), "--key", str(key),
         "--key-id", key_id, "--issuer", issuer, "--wait", "--output-format", "json"],
        capture_output=True, text=True,
    )
    if result.returncode:
        raise RuntimeError("Apple notarization submission failed; no artifact will be published.")
    try:
        response = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise RuntimeError("Apple notarization returned invalid JSON.") from error
    if not isinstance(response, dict) or response.get("status") != "Accepted":
        raise RuntimeError("Apple notarization was not Accepted; no artifact will be published.")
    print("Apple notarization accepted.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact")
    parser.add_argument("--key", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    args = parser.parse_args()
    try:
        submit(args.artifact, args.key, args.key_id, args.issuer)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
