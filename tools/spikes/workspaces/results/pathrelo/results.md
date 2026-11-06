# Path relocatability spike (2026-10-22)

macOS 27.0 / Apple Silicon, External APFS SSD. Raw output: `*.out` and `scripts/` in this directory. Big data was deleted after the run.
Toolchains: go1.26.9, uv 0.12.2 (CPython 3.12), cmake 4.4.2 (Makefiles; ninja is not installed), ccache 4.14.2 and sccache 0.18.0 (release binaries run from scratch), cargo 1.97.1, Xcode 27.0 / Swift 6.4, node 26.11 / npm 11.20.

## Go: dieter module, cmd/dieter (535 packages, 56 of them in the module)

- Without -trimpath:
  - Cold build: 104.7 s.
  - Clone: 56 module packages rebuilt in 32.9 s.
  - `go test` in the clone: 0 of 4 cached.
- With GOFLAGS=-trimpath:
  - Cold build: 98.3 s.
  - Clone: 1 package rebuilt in 7.0 s. That package is `main`, rebuilt because the VCS "modified" stamp changed; most of the time is the link.
  - `go test` in the clone: 4 of 4 cached.
  - An edit rebuilds 2 packages, both correct.
- Caveat: under -trimpath, `runtime.Caller` returns a module-relative path such as `github.com/dbpprt/dieter/internal/zzrelo/c_test.go`, which breaks `internal/testkit/harness.go` and `tools/brandcheck/assets_test.go`.

## Python

- pip venv and uv sync (default), in the clone:
  - Shebangs and activate point to the SOURCE venv.
  - The editable .pth holds the absolute SOURCE src path.
  - `.venv/bin/relo` and `import relo` both run SOURCE code.
  - `pip install` and an activated `uv pip install` write into the SOURCE venv (33 -> 35 entries).
- `uv venv --relocatable` + `uv sync`:
  - Scripts and activate are relative (`#!/bin/sh` exec trick), and installs go into the view.
  - The editable .pth is STILL absolute, so the view imports SOURCE code.
- `uv sync --offline` inside a clone:
  - Takes 0.2-0.3 s and rewrites the editable .pth.
  - For a non-relocatable venv the third-party scripts still use the SOURCE interpreter.
- New-venv cost:
  - Fresh `uv sync --offline` into a new view with a warm cache (clone link-mode): 0.21 s for 862 files.
  - The same with link-mode=copy: 0.71 s.
  - `cp -c -R` of the venv: 0.66 s.
  - Cold-cache uv sync: 2.4 s.
  - pip venv + install: 19.9 s.

## CMake: 60 C files

- Source: configure 2.3 s, build 10.3 s.
- Clone with the in-tree build dir:
  - `cmake --build` returns rc=0 but prints "CMake Error: The current CMakeCache.txt directory ... is different".
  - The binary is stale. The source build is untouched.
- Fresh build dir in the view: configure 1.6 s + build 3.4 s.
- Prefix rewrite (perl, preserving mtimes):
  - 80 build files rewritten in 2.3 s.
  - The next build is a no-op.
  - After editing 2 files, exactly 2 objects rebuild and the output is correct.
- ccache, fresh build dir at the new path:
  - Without base_dir: 0/61 hits.
  - With CCACHE_BASEDIR=<parent> and CCACHE_NOHASHDIR=1: 61/61 hits. The debug info then names the SOURCE path, so add -fdebug-prefix-map.

## Xcode (xcodebuild on a SwiftPM package; 3 targets, 25 files, 53 SwiftCompile tasks), -derivedDataPath inside the view

- Plain: cold build 38 s. Building the clone with its cloned DD recompiles all 53 tasks (25 s), with correct output.
- COMPILATION_CACHE_ENABLE_CACHING=YES, shared COMPILATION_CACHE_CAS_PATH, SWIFT/CLANG_ENABLE_PREFIX_MAPPING and SWIFT/CLANG_ENABLE_PROJECT_PREFIX_MAPPING, fresh DD in the view:
  - Different leaf dir name: 34 hits (SDK pcm) and 28 misses (every project job). Cause: `-package-name` is derived from the directory name.
  - Same leaf dir name (`.../src/Relo` vs `.../view/Relo`): 62/62 hits, 17.8 s. In this tiny fixture, planning and linking dominate.
  - Same path with a fresh DD: 14 s, all hits.

## SwiftPM 6.4 `.build`

- Default swiftbuild backend:
  - Source cold build: 43 s.
  - The clone does a full rebuild (22.5 s) with 76 "Stale file ... outside of the allowed root paths" warnings. Output is correct.
  - Edit + build: 5.9 s, correct.
- `--build-system native` in the clone fails: "precompiled file ... was compiled with module cache path '<source>' ...". The stale binary is left behind and still prints "where=source".

## Cargo: workspace with 3 members, serde/regex, and a cc build script

- Source cold build: 30 s.
- Clone: Fresh=21, Compiling=0, 0.27 s.
- Edit: 2 crates rebuild in 2.9 s, and the output is correct.
- Cargo re-points the build-script link-search and OUT_DIR at the view's target. The view still builds with the source target dir moved away.
- sccache with a fresh target dir in the view: 16/22 Rust hits. The misses are the workspace members plus serde, serde_core and serde_json (OUT_DIR). The numbers are identical with SCCACHE_BASEDIRS=<parent>.

## Node: npm, a local N-API addon, React, lodash-es, Vite 7, TypeScript

- The clone of 1,080 files takes 0.66 s. require and the addon load work.
- The addon .node has no LC_RPATH.
- No files under node_modules contain the source path, and there are no absolute symlinks.
- addon/build (Makefile, config.gypi, .o, .node debug info) does contain the source path.
- `tsc -b` reports "up to date".
- Vite's configHash changes (717e2d34 -> bc88480a), so it re-optimizes: "vite config has changed".

## Detector (rg -F -uuu over untracked and ignored entries)

| Tree           | Files  | Hits  | Time   |
| -------------- | ------ | ----- | ------ |
| tree-dev/small | 1,999  | 0     | 0.84 s |
| tree-dev/js    | 39,999 | 0     | 8.1 s  |
| uv venv        | 986    | 130   | 0.4 s  |
| pip venv       | 2,416  | 1,145 | 0.61 s |
| CMake          | 162    | 143   | 0.33 s |
| Cargo target   | 471    | 159   | 0.49 s |
| SwiftPM .build | 1,592  | 255   | 0.73 s |
| Xcode DD       | 1,614  | 305   | 0.77 s |
| Node           | 1,104  | 4     | 0.48 s |
| Go bin         | 1      | 1     | —      |

The uv venv's 130 hits are 117 pyc, 1 pth, 1 direct_url.json and scripts/activate.

## Slot pool vs fresh clone (tree-dev/js: 5,000 tracked files, 45k total)

- Fresh view: clonefile 2.97 s + first `git status` 1.31 s (index refresh for new inodes) = 4.3 s.
- Slot refresh after agent dirt (50 modified, 200 untracked, 100 ignored junk files, .env.local):

| N commits | Files changed | fetch | reset --hard | clean -ffdx -e node_modules/ | status |
| --------- | ------------- | ----- | ------------ | ---------------------------- | ------ |
| 1         | 20            | 1.8 s | 0.45 s       | 0.26 s                       | 0.18 s |
| 10        | 201           | 1.4 s | 0.38 s       | 0.83 s                       | 0.18 s |
| 100       | 218           | 1.4 s | 1.07 s       | 0.54 s                       | 0.20 s |

- Leftovers: 0. node_modules is kept.
- Worktree slot (shared object DB, no fetch), b0 -> b100: reset 1.55 s + clean 0.28 s + status 0.17 s. Creating it by checkout took 23.8 s once, against 1.9 s for clonefile.
