#!/bin/sh
# Builds the review fixture: Dieter commit 526f3387 (#227, worktrees in empty
# repositories) checked out in a scratch clone, with three bugs planted as
# uncommitted edits (results/2026-11-27/planted-bugs.patch):
#   B1 internal/git/unborn.go              ExitCode == 1  ->  ExitCode != 0
#   B2 internal/git/operations/manager.go  `||` -> `&&` in checkInitialCheckout
#   B3 internal/git/workspace/manager.go   `defer release()` -> `_ = release`
# Writes DIR/fixture (the reviewer's workspace) and DIR/planted.diff (the
# change against base 071f756f, what a card's worktree diff would show).
set -eu
dir=${1:?usage: make_fixture.sh DIR}
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$dir"
git clone -q --shared --no-checkout "$repo" "$dir/fixture"
git -C "$dir/fixture" checkout -q -b review-fixture 526f3387
git -C "$dir/fixture" apply "$here/results/2026-11-27/planted-bugs.patch"
git -C "$dir/fixture" diff 526f3387^ >"$dir/planted.diff"
echo "fixture: $dir/fixture  diff: $dir/planted.diff ($(wc -l <"$dir/planted.diff") lines)"
