#!/usr/bin/env bash
set -euo pipefail

# Keep source-built clients and services on one deterministic SemVer identity.
script_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd)"
latest="$(git -C "$repository_root" tag --list 'v*' --sort=-version:refname | \
    awk '/^v[0-9]+[.][0-9]+[.][0-9]+$/ { print; exit }')"
[[ -n "$latest" ]] || latest="v0.0.0"
IFS=. read -r major minor patch <<<"${latest#v}"
count="$(git -C "$repository_root" rev-list --count HEAD)"
revision="$(git -C "$repository_root" rev-parse --short=8 HEAD)"
dirty=""
git -C "$repository_root" diff --quiet && git -C "$repository_root" diff --cached --quiet || dirty=".dirty"
printf '%s.%s.%s-dev.%s+%s%s\n' "$major" "$minor" "$((patch + 1))" "$count" "$revision" "$dirty"
