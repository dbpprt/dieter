# Agent workspaces on macOS: what is possible

Status: research 2026-10-22 · follows [agent-workspaces-results.md](agent-workspaces-results.md) ·
evidence: [`tools/spikes/workspaces/results/pathrelo`](../../tools/spikes/workspaces/results/pathrelo/results.md)

## The problem

The spike showed that APFS clones give each agent session a private, warm,
copy-on-write view in seconds, and that per-turn snapshots record exactly what
a session changed. What clones cannot give us on macOS is the checkout's
**original path**. Tools that bake absolute paths into ignored state then go
cold or, worse, misbehave silently: a cloned venv's `pip` writes into the
source venv, and a cloned CMake tree reports success without rebuilding.

On Linux, bubblewrap solves this with a mount namespace that puts an overlay at
the original path. This document answers whether macOS has an equivalent, and
what to do instead.

## Short answer

**There is no supported way on macOS to give one process tree a private view
of a path while everything else sees the real directory.** Apple confirmed it
in July 2026: that is "akin to Linux Namespaces… a system-wide feature. All of
macOS would need to participate"
([forum 808728](https://developer.apple.com/forums/thread/808728)).

So we stop chasing the same path, and make the path not matter instead:

1. **Path-safe warm views:** clone views with a fixed layout, a per-toolchain
   environment, and a detector that rebuilds or rewrites the few path-bound
   directories.
2. **Warm slots:** an opt-in pool of long-lived views at stable paths, for
   projects whose caches cannot be made path-independent.
3. **Linux micro-VMs:** an optional backend for repositories that do not need
   Apple toolchains. It is the only same-path option that scales without
   kernel changes.

## Every same-path mechanism, and why it fails

| Mechanism                                                                 | Same path | Concurrent sessions | Blocker                                                                                                                                                                                                          |
| ------------------------------------------------------------------------- | --------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| chroot / `pivot_root`                                                     | yes       | –                   | With SIP on, AMFI kills hardened platform binaries in a chroot; `pivot_root` is restricted to pid 1 with an entitlement ([xnu](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c)) |
| Bind mounts / nullfs                                                      | –         | –                   | Do not exist on macOS                                                                                                                                                                                            |
| Union mounts, firmlinks, `synthetic.conf`                                 | –         | –                   | Global, no copy-up (union mounts are broken on APFS), root plus a reboot                                                                                                                                         |
| Seatbelt / App Sandbox redirection                                        | –         | –                   | Seatbelt only allows or denies; App Sandbox path redirection needs a private entitlement and only rewrites rules                                                                                                 |
| Endpoint Security `AUTH_OPEN`                                             | –         | –                   | Can allow, deny or narrow flags, not redirect                                                                                                                                                                    |
| `DYLD_INSERT_LIBRARIES` (fakechroot-style)                                | partly    | –                   | Stripped for SIP-protected and hardened binaries, so every `/bin/sh` or `/usr/bin/env` in the chain drops it; macOS ptrace cannot trace syscalls                                                                 |
| One loopback NFS server at the checkout, a different view per caller uid  | yes       | **no**              | The kernel name, attribute and data caches are keyed by vnode, not by credential, so views leak between users ([NFS kext](https://github.com/apple-oss-distributions/NFS/blob/main/kext/nfs_subs.c))             |
| FSKit at the checkout, per caller uid                                     | yes       | unverified          | `FSContext` carries uid and gid only; Apple's Security teams have not approved pid or audit token; per-caller name-cache behaviour is undocumented. On top of that, see below                                    |
| macFUSE kext, per uid or pid with `novncache`                             | yes       | yes                 | Needs Reduced Security in Recovery plus a reboot on Apple Silicon, and a paid licence to bundle. Running sessions as separate uids also breaks the keychain, TCC, ssh-agent and simulators                       |
| macOS VMs (Tart, Virtualization.framework) with virtiofs at the same path | yes       | **max 2**           | The macOS licence allows 2 extra instances and Virtualization.framework enforces it; 4–8 GB of RAM each                                                                                                          |
| Apple `container` (Linux VM per session), virtiofs bind at the same path  | yes       | yes                 | Linux only: no Xcode or macOS frameworks; about 1 GB per session; slower virtiofs metadata; no host-to-guest inotify                                                                                             |
| A mount at the checkout only while one session runs                       | yes       | **no**              | Mounts are global, so the operator's checkout is hidden and sessions run one at a time                                                                                                                           |

### FSKit specifically

FSKit is a no-go for 2026 and most of 2027.

- **Broken operations (macOS 27):**
  - `RENAME_SWAP` reports success but destroys the destination (FB24419773). The module receives no flags, so it cannot work around this.
  - `fsync` never reaches path-backed modules (FB24419870).
  - The volume root cannot be invalidated, and there is no change notification.
- **Fragile operation:**
  - One failed activation wedges that source path until `fskitd` is killed.
  - An app update force-unmounts every volume without syncing.
  - Enablement is per user in System Settings, with no MDM payload.
- **Speed:** the closest existing overlay, [Ghosttree](https://github.com/tian000/ghosttree), measured on 5k files:

  | Workload          | Native APFS | Ghosttree FSKit |
  | ----------------- | ----------- | --------------- |
  | warm `git status` | 60 ms       | 330 ms          |
  | cold `git status` | 20 ms       | 2,340 ms        |
  | small-file reads  | 1×          | 7×              |

  Ghosttree is also GPL.

- **It still would not solve the path:** an FSKit overlay gives each session its own mount point, not the original path. It would only replace clone creation and deletion, and clones already take seconds.
- **Revisit when** `RENAME_SWAP`, fsync and root invalidation are fixed, metadata cost is under 2× native, and enablement can be managed.
- **Estimated effort:** a prototype in 3–4 weeks, production in another 8–12.

## Recommended macOS design

### 1. Path-safe warm views (the default)

**Layout.** Each view lives at `<views>/<session>/<repo-name>`, so its leaf
directory name matches the base checkout. Xcode compilation caching and SwiftPM
package names depend on the leaf name: with a different leaf only 34 of 62
compile tasks hit the cache; with the same leaf all 62 hit.

**Per-toolchain environment.** Dieter sets the session environment so caches
are keyed by content, not by path. Measured by building in the base, cloning,
and rebuilding in the clone:

| Toolchain                          | Without mitigation                                                                                                           | Mitigation                                                                                                                                               | With mitigation                                                            |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Go                                 | rebuilds all 56 module packages (32.9 s)                                                                                     | `GOFLAGS=-trimpath` with a shared `GOCACHE`                                                                                                              | 1 package rebuilt, 7.0 s; tests cached                                     |
| Python venv                        | **silently wrong:** scripts run the source interpreter, `pip` writes into the source venv, editable imports load source code | `UV_VENV_RELOCATABLE=1`, then `uv sync --offline` when the view is created                                                                               | correct, 0.2–0.3 s                                                         |
| CMake                              | **silently stale** (exits 0)                                                                                                 | a fresh build dir per view plus ccache (`CCACHE_BASEDIR=<views root>`, `CCACHE_NOHASHDIR=1`, `-fdebug-prefix-map`); or rewrite the path in the build dir | 61/61 cache hits; rewrite took 2.3 s, then incremental builds were correct |
| Xcode                              | full recompile (53/53 tasks, 25 s)                                                                                           | `COMPILATION_CACHE_ENABLE_CACHING=YES`, one shared CAS per project, prefix mapping, same leaf name                                                       | 62/62 hits                                                                 |
| SwiftPM 6.4 `.build`               | full rebuild (22.5 s against 43 s cold); the deprecated native backend leaves a **stale binary**                             | do not clone `.build`; build through xcodebuild with compilation caching, or use a slot                                                                  | –                                                                          |
| Rust / cargo                       | already relocatable: 0 crates recompiled, 0.27 s                                                                             | clone `target/` as is; avoid a shared `CARGO_TARGET_DIR` (lock contention)                                                                               | –                                                                          |
| npm / `node_modules`               | relocatable (relative `.bin` links)                                                                                          | clone as is; Vite re-optimizes (slower, not wrong)                                                                                                       | –                                                                          |
| Gradle, Bazel (from documentation) | Gradle's build cache is relocatable for RELATIVE inputs; Bazel's output base is per path                                     | shared Gradle cache; Bazel `--disk_cache` or a slot                                                                                                      | –                                                                          |

**Caveat on `-trimpath`:** it changes `runtime.Caller`. Dieter's own
`internal/testkit/harness.go` and `tools/brandcheck/assets_test.go` locate
files that way and break under it, so `-trimpath` has to be opt-in per project
(or those tests have to change).

**Path-bound detector.** At base refresh, not per view, run
`rg -F -uuu <base path>` over ignored and untracked files (about 0.2 ms per
file; 8 s for 40k files) and classify each hit:

- **Dangerous:** shebangs, `.pth`, `activate`, `pyvenv.cfg`, `CMakeCache.txt`, Makefile and ninja files, absolute symlinks.
- **Harmless:** `.pyc`, `RECORD`, debug info, `.d` files, cargo dep-info.

Hit counts alone mislead. Cargo has 159 hits and is safe; a relocatable uv
venv has 3, and one of them (the editable `.pth`) imports the wrong code. The
classification decides each directory's policy: keep, rewrite text, exclude
and rebuild, or slot only.

**Catching what the detector misses.** A Seatbelt profile that denies writes
to the source checkout would make leaks fail loudly. However, the earlier
spike showed that any Seatbelt profile breaks nested sandboxes: `swift package`
fails with `sandbox_apply: Operation not permitted`, and Codex's and Claude's
own sandboxes are affected the same way. So use it only for projects without
SwiftPM or Xcode script sandboxing. Otherwise, rely on FSEvents replay over the
source checkout, which flagged every escape in the spike, after the fact.

### 2. Warm slots (opt-in, 2–4 per project)

For projects whose caches cannot be made path-independent (CMake without
ccache, Bazel, heavy SwiftPM, large Vite/Next/Jest caches), keep long-lived
views at stable paths (`~/.dieter/views/<project>/slot-K/<repo-name>`). Their
caches were built at that path, so they stay valid. This is what Codex (15
worktrees), Cursor (25), Factory (LRU of 15) and CI runners (`_work`) do.

**Measured on the `js` fixture** (5k tracked files, 45k entries in total, slow
external disk):

| Operation                                     | Time                               |
| --------------------------------------------- | ---------------------------------- |
| Fresh clone view                              | 2.97 s + 1.31 s first `git status` |
| Slot refresh, 1 commit (20 changed files)     | 2.7 s                              |
| Slot refresh, 10 commits (201 changed files)  | 2.8 s                              |
| Slot refresh, 100 commits (218 changed files) | 3.2 s                              |

Each refresh fetched, ran `reset --hard` and `clean -ffdx` while keeping
`node_modules`, and left nothing behind. The win is not git time: a slot
avoids the full toolchain rebuild at a new path (Go 33 s, SwiftPM and Xcode
22–25 s, a whole CMake build).

**Refresh steps:**

1. Snapshot unpublished work.
2. Kill processes still running in the slot.
3. Re-clone `.git` from the base. `.git/config` hooks, `core.fsmonitor` and
   filter drivers would otherwise execute the previous task's code.
4. Run `reset --hard <base>`.
5. Run `clean -ffdx -e <declared cache dirs>`.
6. Re-sync dependencies when the lockfile hash changed.

Cached directories can hold secrets or poisoned outputs from the previous
task. When every slot is busy, fall back to a clone view.

### 3. Linux micro-VM backend (optional, later)

For repositories that do not need Apple toolchains (Go, Rust, Node, Python,
JVM), Apple's [`container`](https://github.com/apple/container) (1.0, macOS 26+)
runs each session in its own VM.

- **Same path:** bind a host APFS clone at the original path (`-v src:<same path>`). Diffs stay on the host, so the shadow snapshot keeps working.
- **Platform-specific directories:** put guest-local volumes over `.venv`, `node_modules` and `build/`, because macOS binaries do not run in Linux.
- **Concurrency:** no cap; about 1 GB per session.
- **Costs:** virtiofs metadata is slower than native, and host-side changes do not reach inotify in the guest.

## Not recommended

- **Per-uid filesystem multiplexing:** NFS leaks views through shared caches; FSKit only knows the uid; separate users break credentials.
- **macFUSE kext:** requires Reduced Security.
- **chroot or DYLD interposition:** blocked by SIP.
- **FSKit overlay:** wait for the fixes listed above.
- **macOS VMs:** at most 2. Possibly an opt-in for one or two heavy Xcode sessions.

## Next steps

1. Ship the per-turn change record on today's worktree mode. It does not
   depend on any of this.
2. Add view layout and environment profiles (Go, uv, ccache, Xcode CAS) and
   the detector, behind a project setting. Measure on real repositories.
3. Prototype warm slots for one CMake or Bazel project.
4. Track the FSKit feedback numbers above; revisit at macOS 28.
