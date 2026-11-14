#!/bin/sh
# Runs check-api-boundary.sh against small fixture trees: a clean tree and a
# listed violation pass; an unlisted violation, a stale or reasonless entry,
# a type alias and a re-export fail.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHECK="$SCRIPT_DIR/check-api-boundary.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dieter-api-boundary-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
FAILURES=0

# fixture NAME: a tree whose adapter names dieter.v1 and whose feature only
# uses the client contract; cases then add files or allowlist lines.
fixture() {
    tree="$WORK/$1"
    mkdir -p "$tree/Sources/DieterMacKit/Adapters" "$tree/Sources/DieterMacKit/Features/Board"
    printf 'import DieterAPI\n\nfunc title(_ card: Dieter_V1_Card) -> String { card.title }\n' \
        >"$tree/Sources/DieterMacKit/Adapters/CardAdapter.swift"
    printf 'import DieterClientAPI\n\nfunc count(_ slice: ClientBoardSlice) -> Int { slice.cards.count }\n' \
        >"$tree/Sources/DieterMacKit/Features/Board/BoardModel.swift"
    printf '# Files outside Adapters/ that still name the network API.\n\n' >"$tree/api-boundary-allowlist.txt"
}

expect() {
    expected=$1 name=$2
    if sh "$CHECK" "$WORK/$name" >"$WORK/$name.out" 2>&1; then actual=pass; else actual=fail; fi
    if [ "$actual" = "$expected" ]; then
        echo "ok   $name ($actual)"
    else
        echo "FAIL $name: expected $expected, got $actual"
        sed 's/^/     /' "$WORK/$name.out"
        FAILURES=$((FAILURES + 1))
    fi
}

fixture clean
expect pass clean

fixture unlisted
printf '@testable import DieterAPI\n' >"$WORK/unlisted/Sources/DieterMacKit/Features/Board/BoardView.swift"
expect fail unlisted

fixture listed
printf 'import struct DieterAPI.Dieter_V1_Card\n' >"$WORK/listed/Sources/DieterMacKit/Features/Board/BoardView.swift"
printf 'Sources/DieterMacKit/Features/Board/BoardView.swift edits a card\n' >>"$WORK/listed/api-boundary-allowlist.txt"
expect pass listed

fixture reference
printf 'let card: Dieter_V1_Card? = nil\n' >"$WORK/reference/Sources/DieterMacKit/Features/Board/BoardView.swift"
expect fail reference

fixture stale
printf 'Sources/DieterMacKit/Features/Board/BoardModel.swift no longer needed\n' >>"$WORK/stale/api-boundary-allowlist.txt"
expect fail stale

fixture missing
printf 'Sources/DieterMacKit/Features/Board/Gone.swift deleted file\n' >>"$WORK/missing/api-boundary-allowlist.txt"
expect fail missing

fixture reasonless
printf '@preconcurrency import DieterAPI\n' >"$WORK/reasonless/Sources/DieterMacKit/Features/Board/BoardView.swift"
printf 'Sources/DieterMacKit/Features/Board/BoardView.swift\n' >>"$WORK/reasonless/api-boundary-allowlist.txt"
expect fail reasonless

fixture alias
printf 'typealias Card = Dieter_V1_Card\n' >>"$WORK/alias/Sources/DieterMacKit/Adapters/CardAdapter.swift"
expect fail alias

fixture exported
printf '@_exported import DieterAPI\n' >"$WORK/exported/Sources/DieterMacKit/Adapters/Exports.swift"
expect fail exported

if [ "$FAILURES" -ne 0 ]; then
    echo "check-api-boundary-test: $FAILURES case(s) failed" >&2
    exit 1
fi
echo "check-api-boundary-test: all cases passed"
