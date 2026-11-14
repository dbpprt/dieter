#!/bin/sh
# E2: do toolchains survive a copy-on-write clone at a NEW path (or an overlay
# at the SAME path)? e2-toolchains.sh ROOT SPIKE [overlay]
set -u
ROOT=$1 SPIKE=$2 MODE=${3:-clone}
unset DIETER_TURN_TOKEN DIETER_HOME DIETER_CARD_ID GIT_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
OS=$(uname -s)
rm -rf "$ROOT"
mkdir -p "$ROOT"
S=$ROOT/source
if [ "$OS" = Linux ] && command -v btrfs >/dev/null; then btrfs subvolume create "$S" >/dev/null; else mkdir -p "$S"; fi
cd "$S" || exit 1
git init -q -b main && git config user.name e2 && git config user.email e2@example.invalid
printf '.build/\nnode_modules/\n.venv/\nbin/\n' >.gitignore
# Go module with a few packages.
mkdir -p gomod/a gomod/b && cd gomod && go mod init example.com/e2 >/dev/null 2>&1
for p in a b; do printf 'package %s\n\nfunc F() int { return %d }\n' $p ${#p} >$p/$p.go; done
printf 'package main\n\nimport (\n\t"fmt"\n\t"example.com/e2/a"\n\t"example.com/e2/b"\n)\n\nfunc main() { fmt.Println(a.F() + b.F()) }\n' >main.go
cd "$S"
# Node project with a vendored tarball dependency.
mkdir -p vendor/leftpad web && printf '{"name":"leftpad-local","version":"1.0.0","main":"index.js","bin":{"lp":"cli.js"}}' >vendor/leftpad/package.json
printf 'module.exports=(s,n)=>s.padStart(n);\n' >vendor/leftpad/index.js
printf '#!/usr/bin/env node\nconsole.log(require("./index.js")("x",3));\n' >vendor/leftpad/cli.js
(cd vendor && npm pack ./leftpad --silent >/dev/null 2>&1)
printf '{"name":"web","version":"1.0.0","private":true}' >web/package.json
(cd web && npm install --silent --no-audit --no-fund ../vendor/leftpad-local-1.0.0.tgz >/dev/null 2>&1)
# Python venv.
python3 -m venv .venv
# SwiftPM (macOS only).
if [ "$OS" = Darwin ]; then
    mkdir -p swiftpkg && (cd swiftpkg && swift package init --type executable --name E2Swift >/dev/null 2>&1)
fi
# CMake project (configured in-tree build dir).
if command -v cmake >/dev/null; then
    mkdir -p cproj && printf 'cmake_minimum_required(VERSION 3.10)\nproject(e2c C)\nadd_executable(e2c main.c)\n' >cproj/CMakeLists.txt
    printf 'int main(void){return 0;}\n' >cproj/main.c
    printf 'cproj/build/\n' >>.gitignore
fi
git add -A && git commit -qm e2
# Build everything at the original path.
t0=$(date +%s)
(cd gomod && go build -o ../bin/e2 .) && echo "source go build: ok ($(($(date +%s) - t0))s)"
if [ "$OS" = Darwin ]; then
    t0=$(date +%s)
    (cd swiftpkg && swift build >/dev/null 2>&1) && echo "source swift build: ok ($(($(date +%s) - t0))s)"
fi
if command -v cmake >/dev/null; then (cmake -S cproj -B cproj/build >/dev/null 2>&1 && cmake --build cproj/build >/dev/null 2>&1) && echo "source cmake build: ok"; fi
echo "source venv pip: $(.venv/bin/pip --version | sed 's/ (python.*//')"
# The view.
if [ "$MODE" = overlay ]; then
    base=$ROOT/base
    btrfs subvolume snapshot -r "$S" "$base" >/dev/null
    mkdir -p "$ROOT/upper" "$ROOT/work"
    W="$SPIKE bwrap-retry bwrap --dev-bind / / --overlay-src $base --overlay $ROOT/upper $ROOT/work $S --chdir $S --unshare-pid --proc /proc --die-with-parent --"
    V=$S
    echo "view: overlay at the same path $S"
else
    V=$ROOT/view
    "$SPIKE" clone "$S" "$V"
    W=""
    echo "view: clone at $V"
fi
run() { if [ -n "$W" ]; then $W sh -c "$1"; else (cd "$V" && sh -c "$1"); fi; }
echo "--- in the view"
run 'cd gomod && go build -v -o ../bin/e2 . 2>&1 | sed "s/^/  go rebuilt: /"; ../bin/e2 >/dev/null && echo "go build: ok"'
run 'cd gomod && go list -f "{{.Dir}}" . | sed "s/^/  go package dir: /"'
if [ "$OS" = Darwin ]; then
    run 't0=$(date +%s); cd swiftpkg && if swift build > ../swift.log 2>&1; then echo "swift build: ok ($(($(date +%s)-t0))s)"; else echo "swift build: FAILED"; tail -3 ../swift.log; fi; grep -c "Compiling" ../swift.log | sed "s/^/  swift compile steps: /"'
    run 'cd swiftpkg && f=$(ls Sources/*/*.swift | head -1) && printf "print(\"view-edit\")\n" > "$f" && swift build > ../swift2.log 2>&1; out=$(swift run -q 2>/dev/null | tail -1); echo "swift after editing in the view: prints \"$out\" (expected view-edit)"'
fi
run 'cd web && node -e "console.log(\"node require: \"+JSON.stringify(require(\"leftpad-local\")(\"x\",3)))" && ./node_modules/.bin/lp >/dev/null && echo "node .bin: ok"; ls -l node_modules/.bin/lp | sed "s/.*-> /  .bin target: /"'
run 'head -1 .venv/bin/pip | sed "s/^/  pip shebang: /"; .venv/bin/pip --version | sed "s/ (python.*//;s/^/  pip runs from: /"; .venv/bin/python -c "import sys; print(\"  venv python prefix: \"+sys.prefix)"'
if command -v cmake >/dev/null; then
    run 'sleep 1; printf "int main(void){return 1;}\n" > cproj/main.c; before=$(ls -l --full-time cproj/build/e2c 2>/dev/null || stat -f %m cproj/build/e2c); cmake --build cproj/build > cmake.log 2>&1; rc=$?; after=$(ls -l --full-time cproj/build/e2c 2>/dev/null || stat -f %m cproj/build/e2c); if [ "$before" = "$after" ]; then echo "cmake --build after editing main.c in the view: exit $rc, view binary NOT rebuilt (stale)"; else echo "cmake --build after edit: exit $rc, rebuilt"; fi; grep -m1 -o "is different than the directory [^ ]*" cmake.log | sed "s/^/  cmake warning: /"'
fi
echo "--- done"
