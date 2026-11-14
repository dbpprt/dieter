#!/bin/sh
# Checks the Mac app's schema-first API boundary. DieterMacKit names the
# network API (DieterAPI: the dieter.v1 and gateway messages) only in its
# protocol adapters, Sources/DieterMacKit/Adapters/; everything else works with
# the core's client contract (DieterClientAPI) and Mac presentation values.
#
# A Swift file outside Adapters/ that imports DieterAPI or DieterAPIGRPC (in any
# form) or contains `Dieter_V1_` must be listed in api-boundary-allowlist.txt as
# `<path relative to apps/apple/mac> <reason>`. An entry whose file no longer
# violates (or is gone) fails the check, so the list can only shrink. Nothing in
# DieterMacKit, Adapters/ included, may re-export DieterAPI or alias a dieter.v1
# or gateway type.
#
#   check-api-boundary.sh [MAC_PACKAGE_ROOT]
#
# The optional root (default: the package this script belongs to) lets
# check-api-boundary-test.sh run the check against fixture trees.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "${1:-$SCRIPT_DIR/..}" && pwd)
KIT=Sources/DieterMacKit
ADAPTERS=$KIT/Adapters/
ALLOWLIST=api-boundary-allowlist.txt

# `import DieterAPI`, `@testable import`, `@preconcurrency import`,
# `public import`, `@_exported import`, `import struct DieterAPI.X`, ...
IMPORT_RE='^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*((public|package|internal|fileprivate|private)[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?DieterAPI(GRPC)?([[:space:].]|$)'
ALIAS_RE='typealias[[:space:]][^=]*=.*Dieter_(Gateway_)?V1_'

cd "$ROOT"
if [ ! -d "$KIT" ]; then
    echo "api-boundary: no $KIT under $ROOT" >&2
    exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dieter-api-boundary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
export LC_ALL=C

# path:line:text of every DieterAPI import, Dieter_V1_ line and type alias.
# (/dev/null keeps the file name in grep's output; grep exits 1 on no match.)
find "$KIT" -type f -name '*.swift' -exec grep -nE "$IMPORT_RE" /dev/null {} + >"$WORK/imports" || true
find "$KIT" -type f -name '*.swift' -exec grep -n 'Dieter_V1_' /dev/null {} + >"$WORK/refs" || true
find "$KIT" -type f -name '*.swift' -exec grep -nE "$ALIAS_RE" /dev/null {} + >"$WORK/aliases" || true

outside_adapters() {
    awk -v prefix="$ADAPTERS" 'index($0, prefix) != 1'
}

cat "$WORK/imports" "$WORK/refs" | cut -d: -f1 | outside_adapters | sort -u >"$WORK/violating"

: >"$WORK/errors"
: >"$WORK/allowed"
if [ -f "$ALLOWLIST" ]; then
    awk -v errors="$WORK/errors" -v list="$ALLOWLIST" '
        { sub(/\r$/, "") }
        /^[ \t]*(#|$)/ { next }
        {
            entry = $0
            sub(/^[ \t]+/, "", entry)
            path = entry
            sub(/[ \t].*$/, "", path)
            reason = substr(entry, length(path) + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", reason)
            if (reason == "") {
                printf "%s:%d: entry without a reason: %s\n", list, NR, path >errors
            } else if (path in seen) {
                printf "%s:%d: duplicate entry: %s\n", list, NR, path >errors
            } else {
                seen[path] = 1
                print path
            }
        }' "$ALLOWLIST" | sort >"$WORK/allowed"
fi

comm -23 "$WORK/violating" "$WORK/allowed" | while IFS= read -r path; do
    echo "$path: outside Adapters/ and names the network API, but is not in $ALLOWLIST:"
    awk -F: -v path="$path" '$1 == path' "$WORK/imports" "$WORK/refs" | sort -t: -k2,2n -u | sed -n '1,3s/^/    /p'
done >>"$WORK/errors"
comm -13 "$WORK/violating" "$WORK/allowed" | while IFS= read -r path; do
    if [ -f "$path" ]; then
        echo "$ALLOWLIST: stale entry (no longer violates; delete the line): $path"
    else
        echo "$ALLOWLIST: stale entry (no such file under $KIT outside Adapters/): $path"
    fi
done >>"$WORK/errors"
grep '@_exported' "$WORK/imports" | sed 's/^/re-exports the network API: /' >>"$WORK/errors" || true
sed 's/^/aliases a network API type: /' "$WORK/aliases" >>"$WORK/errors"

occurrences() {
    awk '{ total += gsub(/Dieter_V1_/, "&") } END { print total + 0 }'
}
count_lines() {
    wc -l | tr -d ' '
}
VIOLATING=$(count_lines <"$WORK/violating")
ALLOWED=$(count_lines <"$WORK/allowed")
IMPORTING=$(cut -d: -f1 "$WORK/imports" | sort -u | count_lines)
IMPORTING_OUTSIDE=$(cut -d: -f1 "$WORK/imports" | outside_adapters | sort -u | count_lines)
REFERENCES=$(occurrences <"$WORK/refs")
REFERENCES_OUTSIDE=$(outside_adapters <"$WORK/refs" | occurrences)

if [ -s "$WORK/errors" ]; then
    sed 's/^/api-boundary: /' "$WORK/errors" >&2
    echo "api-boundary: FAILED. Keep dieter.v1 and gateway types in $ADAPTERS (protocol plumbing) and use" \
        "DieterClientAPI slices elsewhere; list a file only when no client slice row exists yet." >&2
fi
echo "api-boundary: $VIOLATING violating files outside Adapters/ ($ALLOWED allowlisted);" \
    "DieterAPI imported by $IMPORTING files ($IMPORTING_OUTSIDE outside Adapters/);" \
    "Dieter_V1_ references: $REFERENCES total, $REFERENCES_OUTSIDE outside Adapters/"
[ ! -s "$WORK/errors" ]
