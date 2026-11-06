# Proposal: copy-on-write agent workspaces with exact change records

Status: spike completed 2026-10-21; results and plan corrections in
[agent-workspaces-results.md](agent-workspaces-results.md) · proposed
2026-10-20 · scope: `internal/git/workspace`, `internal/engine` turn
lifecycle, harness runtime; spike code in
[`tools/spikes/workspaces`](../../tools/spikes/workspaces/README.md)

## TL;DR

Git worktrees give each card its own checkout. They don't give it its
dependencies, build caches or `.env`, and they don't say what a turn changed.
[LayerFS](https://github.com/Ephemeral-AI-Lab/layerfs) solves both with one
FUSE daemon and its own content-addressed store. We can get the same
properties from native primitives plus git by splitting the problem into three
layers:

1. **View: where a conversation's files live.**
   - **macOS:** an APFS `clonefile` of the whole checkout. It includes
     ignored files and needs no root, no extension and no approval prompt.
     Measured: 1.3 s for 20k files, 9.3 s for 166k entries.
   - **Linux:** a kernel overlayfs in a per-session user and mount
     namespace, created with bubblewrap and mounted at the checkout's
     _original path_. Verified unprivileged on `garuda`: Linux 6.18,
     bubblewrap 0.12, btrfs.
2. **Record: what a turn changed.** Take a tree snapshot at every turn
   boundary through a private index into a shadow object store in
   `DIETER_HOME`. The diff of two consecutive snapshots is exactly what the
   turn changed, including shell edits, formatters and codegen. Measured on
   this repository: 0.16–0.25 s, with nothing written to the project
   repository. Ignored paths get a separate stat manifest.
3. **Attribution: who changed it.** It comes from structure: each
   conversation has its own view, and the existing invariant allows only one
   active turn per conversation. Harness reports become hints only. Codex's
   turn diff does not see shell edits at all, and Claude's coverage of Bash
   edits is a git-only beta.

Not now:

- **FSKit overlay:** feasible on macOS 26+, but 27.0 has data-loss-class
  bugs and needs per-user enablement.
- **macFUSE / FUSE-T:** their licences forbid bundling.
- **NFS loopback:** the EdenFS and AgentFS pain.
- **Seatbelt write observer:** it breaks SwiftPM (verified below).
- **Endpoint Security:** it needs an entitlement Apple rarely grants.

The spike takes 6–8 days on this Mac (`/Volumes/External`) and `garuda`. A
deterministic scenario catalog runs through a script driver, then through real
Codex and real Claude sessions. Each run compares what the harness reported
and what our recorders captured against an independent filesystem oracle.
Section 5 sets out the gates.

---

## 1. Why worktrees hurt today

| Problem                         | Evidence                                                                                                                                                                                                                                                          |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fresh checkout, no dependencies | `git worktree add [-b dieter/<id12>-<slug>] <path> <baseRef>` (`internal/git/workspace/manager.go:194-202`). It brings no `node_modules`, build output or `.env`, so every card pays install and build again.                                                     |
| Created on the first turn       | `Manager.Ensure` runs lazily at turn admission (`internal/engine/turn_admission.go:138`), so the first turn waits for the checkout.                                                                                                                               |
| No garbage collection           | Archive and the done-card sweep leave worktrees behind (`internal/store/kanban/cards.go:654-714`). Nothing runs `git worktree prune`.                                                                                                                             |
| No per-turn record              | Changes are `git status` and `git diff` run on demand (`internal/git/status.go`, `internal/git/changeset/service.go`). `ConversationTurn` has no change fields. In project mode, changes cannot be attributed to a card (`Volatile`).                             |
| Harness data is dropped         | The Codex adapter ignores `turn/diff/updated` and reduces `fileChange` items to `{path, kind}`. The Claude adapter does not enable checkpointing.                                                                                                                 |
| Path-keyed agent state leaks    | `~/.codex/config.toml` already holds 72 trust entries, including 12 `.build/smoke/core-*` and 8 `quick-title-workspaces/title-*` directories. Every new path adds one. Claude adds a `~/.claude/projects/<slug>` directory and a `~/.claude.json` entry per path. |

## 2. Requirements

1. **Isolation per conversation, including ignored files.** It must work for
   any tool the agent runs, not only its edit tools.
2. **Creation cost that does not grow with repository bytes.** Seconds, not
   minutes, and no reinstalling.
3. **Cheap fork and discard.**
4. **An exact record per turn.** That means create, modify, delete, rename,
   mode, symlink and type changes, from edit tools, shell commands,
   formatters, codegen and dependency installs. Writes after the turn and
   writes outside the view are detected and reported, not silently mixed in.
5. **Git mapping.** Branch, commit, PR and conflict preview, without touching
   the operator's checkout or its index.
6. **macOS and Linux**, without root, kernel extensions or new
   approval prompts by default.
7. **The [invariants](../invariants.md).** All data under `DIETER_HOME`, no
   Dieter metadata in project repositories, atomic writes under the central
   lock, concurrent turns allowed, harness workers unsandboxed (or an ADR).

## 3. Research findings

### 3.1 LayerFS, the inspiration

- **Implementation:** Rust FUSE on a vendored, patched `fuser` 0.18. One
  SQLite store holds immutable content-addressed chunks (BLAKE3, zstd and
  deltas), and each Workspace has its own `overlay.sqlite` delta.
- **Usage model:** each Bash call mounts a Workspace, runs, commits and
  unmounts. A commit onto a Branch that has moved does a three-way merge
  first and refuses on conflict. A `.lww` file names paths where the newest
  edit wins.
- **Runtime requirements:** Linux and Docker, with `CAP_SYS_ADMIN`,
  `/dev/fuse` and AppArmor unconfined. Since 2026-10-10 its seccomp filter
  also denies `CLONE_NEWUSER`, so bubblewrap-based agent sandboxes fail
  inside it. Each mount gets a new path.
- **Missing pieces:** no git export, no "agent or call attribution" (its own
  SDK reference says so), no crash durability. Status: 0.1.7 developer
  preview.

**What to take:** an immutable base plus a per-session delta that _is_ the
change set, commits at execution boundaries, refusing on conflict, and a
`.lww`-style policy for generated files. **What to leave:** a private store
(git is our store), FUSE in the I/O path, Docker, and Linux-only design.

### 3.2 View mechanisms

| Mechanism                                                                       | Platform         | Privilege                                                       | Change set is exact?                                   | Same path?        | Verdict                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------- | ------------------------------------------------------ | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| git worktree (today)                                                            | both             | none                                                            | tracked and untracked only, via git                    | no                | Baseline. No dependencies, slow on big trees.                                                                                                                                                                                                                                 |
| APFS `clonefile(2)` on a directory                                              | macOS            | none                                                            | needs a scan (see 3.3)                                 | no                | **Use.** One atomic call. 1.3 s for 20k files, 9.3 s for 166k entries (about 58 MB of metadata). `rm -rf` of 166k entries takes about 40 s, so discard in the background. Same volume only (`EXDEV`). Writes can hit `ENOSPC` later. Hard links split and setuid is stripped. |
| `cp -c -R` / `COPYFILE_CLONE`                                                   | macOS            | none                                                            | needs a scan                                           | no                | Fallback only. 96 s for 166k entries, and not atomic.                                                                                                                                                                                                                         |
| APFS snapshots                                                                  | macOS            | root plus an entitlement Apple grants only to backup vendors    | volume-wide                                            | n/a               | Dead end.                                                                                                                                                                                                                                                                     |
| Disk image with `--shadow`                                                      | macOS            | unverified                                                      | block level, no file diff                              | no                | Dead end. Needs a full data copy into the image.                                                                                                                                                                                                                              |
| FSKit overlay (`FSPathURLResource`, macOS 26; data caching and `FSContext`, 27) | macOS            | user enables it in Settings, per user, again after each re-sign | yes (the upper store)                                  | no                | Later. 27.0 bugs: `RENAME_SWAP` destroys the destination, fsync never reaches the module, no byte-range locks. No pid. Apple DTS says it is not ready for network-style filesystems.                                                                                          |
| macFUSE 5 FSKit backend / FUSE-T                                                | macOS            | install                                                         | yes                                                    | no                | Dead end. The macFUSE licence forbids commercial bundling, FUSE-T is non-commercial only, and the macFUSE FSKit backend is "not on par" with the kext.                                                                                                                        |
| NFSv3 loopback (go-nfs; how AgentFS and EdenFS run on macOS)                    | macOS            | a user may mount on a directory they own                        | yes                                                    | no                | Dead end. No `forget`, no pid, "Server connections interrupted" dialogs. AgentFS's `git add` fails inside its mount ([#333](https://github.com/tursodatabase/agentfs/issues/333)).                                                                                            |
| Apple `container` with overlayfs in the guest                                   | macOS 26+        | none                                                            | yes                                                    | in the guest only | Niche. Linux toolchains only, so no Xcode or simctl.                                                                                                                                                                                                                          |
| overlayfs in a user namespace (bubblewrap ≥ 0.11 `--overlay-src`/`--overlay`)   | Linux ≥ 5.11     | none                                                            | **yes**: upper files, whiteouts, `user.overlay.opaque` | **yes**           | **Use.** Verified on garuda. Directory renames return `EXDEV` (`mv` falls back to copy and delete). Copy-up gives false positives. The lower layer must be frozen. Servers outside the namespace (dockerd, Gradle daemon, watchman, tmux) see the host tree.                  |
| btrfs subvolume snapshot                                                        | Linux            | creating is unprivileged; `send`/`find-new` diffs need root     | needs a scan without root                              | no                | Good frozen _base_ for overlay. garuda's `/home` is btrfs.                                                                                                                                                                                                                    |
| Reflink (`FICLONE`, `cp --reflink`)                                             | Linux, btrfs/XFS | none                                                            | needs a scan                                           | no                | Fallback base or view.                                                                                                                                                                                                                                                        |
| ZFS clone plus `zfs diff`                                                       | Linux            | mounting needs root                                             | yes                                                    | no                | Not by default.                                                                                                                                                                                                                                                               |
| fuse-overlayfs / go-fuse union                                                  | Linux            | fusermount3                                                     | yes                                                    | yes               | Fallback when user namespaces are blocked. FUSE passthrough needs initial-namespace `CAP_SYS_ADMIN`.                                                                                                                                                                          |

Directory `clonefile` is atomic because it locks the source hierarchy while
it runs. Apple DTS warns that, worst case, a long clone of a busy hierarchy
could stall the kernel into a panic
([forum 784446](https://developer.apple.com/forums/thread/784446)). We must
therefore never clone the operator's live checkout, or a running session's
view, in one call. Clone from a quiescent base that Dieter owns (section 4.2).

Probe on garuda: an unprivileged `bwrap --overlay` over `base/`, with commands
run inside the namespace. The upper directory came out as a self-describing
change set:

```text
c c--------- 0 ./old.txt        # whiteout: deleted
f -rw------- 13 ./keep.txt      # copied up and modified (user.overlay.origin)
f -rw------- 4 ./new.txt        # created
d ./dir                         # user.overlay.opaque="y": replaced directory
f ./dir2/f.txt                  # dir rename = EXDEV, so mv copied it
```

On the host, the mount point stayed empty. The overlay `workdir` is left
with mode 000 and needs `chmod` before it can be deleted.

### 3.3 Change records

| Source                                                               | Shell edits? | Ignored files? | Cost / limits                                                                                                                                                                                                                                                                                                                                                                                                                    | Verdict                                                                 |
| -------------------------------------------------------------------- | ------------ | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Codex 0.163 `fileChange` and `turn/diff/updated`                     | **no**       | n/a            | The turn diff is built "from committed apply_patch mutations, without rereading the workspace filesystem" (`codex-rs/core/src/turn_diff_tracker.rs`). One non-exact delta invalidates it for the rest of the turn. Command items have no write classification. Ghost snapshots and `/undo` were removed in 0.126 ([#19481](https://github.com/openai/codex/pull/19481)).                                                         | Hint                                                                    |
| Claude Code 2.1.303: Edit/Write/NotebookEdit results and checkpoints | partly       | no             | Edit and Write results include a `structuredPatch`. Checkpoints exclude Bash edits. `bashEditDiff` is a public beta: git-tracked files only, at most 200 paths, on only with `bashEditDiffEnabled` or in auto/bypass mode, and `skipped` for checkout and stash.                                                                                                                                                                 | Hint                                                                    |
| Private-index tree snapshot into a shadow object store               | **yes**      | no             | Copy the index, then `GIT_INDEX_FILE=… GIT_OBJECT_DIRECTORY=<shadow> git add -A && git write-tree`. **Measured on this repository** (2,660 tracked files): 0.25 s cold, 0.16 s warm. Four new objects landed in the shadow store and the project's `.git` was untouched. In a fresh clone, inode and ctime differ: the first `git status` drops from 4.87 s to 0.30 s with `core.checkStat=minimal` and `core.trustCtime=false`. | **Record**                                                              |
| Stat manifest of ignored paths                                       | yes          | **yes**        | macOS: a `getattrlistbulk` scan with `ATTR_CMNEXT_CLONEID` (unchanged until the data diverges) and `ATTR_CMNEXT_PRIVATESIZE` (bytes that diverged). 2–9 s for 166k entries, single-threaded. The clone-ID behaviour is observed, not documented. Linux: walk the overlay upper directory.                                                                                                                                        | **Record** for ignored paths, as counts plus a list for small sets      |
| FSEvents with `sinceWhen` event IDs                                  | yes          | yes            | No pid. Flags are coalesced, and drops force a rescan.                                                                                                                                                                                                                                                                                                                                                                           | Bounds scans. Detects writes into the operator's checkout during a turn |
| Jujutsu working-copy snapshots                                       | yes          | no             | The same idea as the private-index snapshot. Workspaces still lack dependencies, and it doesn't run git hooks.                                                                                                                                                                                                                                                                                                                   | Borrow the idea, not the dependency                                     |

### 3.4 Attribution

- **Structural, at turn granularity.** Each conversation has its own view,
  and only one turn per conversation runs at a time (an invariant). So
  `diff(T_start, T_end)` belongs to that turn, whichever process wrote it. It
  costs nothing.
- **Per tool call.** Snapshot from `PostToolUse` hooks. Codex hooks are on by
  default, and Dieter already injects a Codex `PreToolUse` hook. Each
  snapshot costs about 0.2 s here. The spike decides whether this pays off
  for Bash calls only.
- **Per process, macOS: Seatbelt `(with report)`.** It logs every allowed
  write under a session tag without root. **Verified blocker:** under an
  allow-everything observer profile, every nested `sandbox_apply` fails.
  A nested `sandbox-exec` was killed (exit 137), and `swift package
dump-package` failed with `sandbox_apply: Operation not permitted`. The
  observer therefore breaks SwiftPM, Xcode script sandboxing and the agents'
  own sandboxes. Diagnostic use only.
- **Per process, otherwise.**
  - **Endpoint Security:** needs root, Full Disk Access and an
    Apple-approved entitlement. Managed builds only.
  - **Linux:** eBPF by cgroup needs root. Unprivileged fanotify gives no pid.
    seccomp-notify is best effort (Anthropic's sandbox-runtime uses it).
- **Shared checkout (project mode).** No structural attribution is
  possible, so it stays `Volatile`. GitButler tried attributing edits in one
  directory through Claude hooks. It missed Bash edits and raced, and it
  removed the integration in May 2026
  ([PR #13850](https://github.com/gitbutlerapp/gitbutler/pull/13850)).

### 3.5 Prior art in one line each

- **AgentFS:** a SQLite delta over the host directory. On macOS it runs an
  NFSv3 server plus `sandbox-exec`, `git add` breaks inside the mount, and
  "audit" means only tool calls it was told about.
- **EdenFS:** NFS on macOS with a root privhelper. Meta documents the hangs
  and unmount dialogs.
- **Scalar** replaced VFS for Git with sparse checkout plus FSMonitor.
- **container-use:** a container plus a branch in a fork repo.
- **Codex app:** worktrees on a detached HEAD, a snapshot before delete,
  `.worktreeinclude`.
- **Claude Code:** `--worktree` and `EnterWorktree`. A `WorktreeCreate`
  hook can supply any directory, so a host could hand out a clone instead.
- **Cursor, Conductor, Factory, Vibe Kanban:** worktrees plus setup scripts
  and retention caps.
- **Cloud sandboxes** (E2B, Modal, Morph, Sprites, Replit): fork at the VM or
  chunk level, and none gives a file-level diff. Git stays the exchange
  format.

The consensus in 2026: locally, worktrees plus include lists and setup
scripts; in the cloud, VM snapshots; and only overlay filesystems capture
shell edits. Nobody ships a copy-on-write view with exact diffs on macOS.

## 4. Proposed design (what the spike validates)

```text
operator checkout                      untouched; watched with FSEvents for escapes
  └─ base (per checkout)               quiescent clone or frozen lower, owned by Dieter, refreshed when idle
       └─ view (per conversation)      clone | overlay upper | worktree fallback
            └─ turn snapshots T0..Tn   trees in a shadow object store under DIETER_HOME
                 └─ publish            branch / PR / merge; the only step that writes to the project repo
```

### 4.1 View providers

```go
type Provider interface {
	Create(ctx context.Context, base Base, id string) (View, error)
	Fork(ctx context.Context, parent View, id string) (View, error) // at a turn boundary
	Discard(ctx context.Context, v View) error                       // rename to trash, delete async
	Command(v View, argv []string) ExecSpec                          // cwd plus wrapper (bwrap on Linux)
}
```

**`apfs-clone` (macOS).**

- The base is one `clonefile` of the checkout, refreshed by re-cloning and
  swapping atomically when no session is cloning from it.
- A view is `clonefile(base)`. A fork is `clonefile(view)` between turns.
- The spike tests two variants:
  - **(a) full clone including `.git`.** An independent repository on a
    detached HEAD. Agents can commit freely and branch names never collide.
    Publishing runs `git fetch <view> <sha>:refs/heads/dieter/<card>` in the
    project repo.
  - **(b) a registered worktree filled by clone.** Run
    `git worktree add --no-checkout --detach`, clone everything except `.git`
    into it, and seed the index from the main index. The `--git-common-dir`
    assumptions of `internal/git/operations` and `changeset` keep working
    unchanged.
- The view's own git config sets `core.checkStat=minimal` and
  `core.trustCtime=false`.
- Clone roots go under a `*.noindex` directory excluded from Time Machine.

**`overlay` (Linux).**

- The base is a frozen lower: a btrfs snapshot when the checkout is on btrfs,
  otherwise a reflink or plain copy refreshed when idle.
- The upper and work directories live in `DIETER_HOME` on the same
  filesystem.
- The harness runner starts as
  `bwrap --dev-bind / / --overlay-src BASE --overlay UP WORK <checkout> --chdir <checkout> -- node runner.mjs`.
- The path stays the same. Absolute-path caches, `pwd -P` checks
  (`runner.mjs:84-93`) and the session symlink binding
  (`local-sandbox.mjs:138-183`) keep working unchanged. Path-keyed agent
  state (`~/.claude/projects/<slug>`) is shared between views; resuming by ID
  still works.

**`worktree` (fallback).** Today's provider, plus `cp -c` or reflink copies of
an allow-list of ignored directories.

### 4.2 Change record

- **Shadow repository** per project, under `DIETER_HOME/workspaces/<project>/`.
  It is a bare repository whose `objects/info/alternates` points at the
  project's object directory.
- **Snapshots:** taken at `T_start` (before admission) and `T_end` (after the
  turn ends and its process group goes quiet). Each one is a tree from the
  private index plus `commit-tree` onto the previous snapshot. The ref goes
  in the shadow repository (`refs/turns/<conversation>/<n>`), never in the
  project repository.
- **Turn diff:** `diff-tree T_start T_end`. It ignores HEAD movement. When an
  agent commits, switches branches or stashes, record the view's refs before
  and after as well, and report those changes as git operations.
- **Ignored paths:** a stat manifest of ignored paths, plus a content hash
  for small allow-listed files such as `.env`. Report counts per top-level
  ignored directory. Ignored content never goes into git objects.
- **Late writers:** anything written after `T_end` goes to the next turn's
  "background" bucket.
- **Escapes:** a write into the operator's checkout while only isolated
  sessions are active raises an "escape" warning with its time window (no
  pid). On Linux the checkout path is overlaid, so such escapes cannot
  happen.
- **Harness reports:** Codex `fileChange` diffs and Claude `structuredPatch`
  keep driving the live UI. At `T_end` they are reconciled against the
  record, and the disagreement is logged.

### 4.3 Git mapping

- **Publish:** fetch the final snapshot, or a squash `commit-tree` of its tree
  on the base, into `refs/heads/dieter/<card>` with a compare-and-swap
  `update-ref`. This is the only write to the project repository.
- **Conflict preview:** `git merge-tree --write-tree <base-tip> <T_last>`. No
  checkout is involved.
- **Later:** a `.lww`-style per-project pattern list, so that generated
  files and lockfiles are regenerated instead of merged.

### 4.4 Invariant impact (ADRs needed)

- **No metadata in project repositories:** satisfied, because the shadow
  store keeps snapshots out of them. Publishing writes branches, as worktree
  mode already does.
- **All data under `DIETER_HOME`:** violated whenever the checkout is on
  another volume. Clones only work within one volume (`EXDEV`), so a
  checkout on `/Volumes/External` needs its clone root on that volume. This
  needs an ADR for registered per-volume roots, with the worktree as
  fallback.
- **Harness workers run without a sandbox:** a Linux mount namespace changes
  what the worker sees, though it confines nothing. This needs an ADR. A
  macOS clone needs none.
- **Replication never copies a working tree:** unaffected, because views are
  local to the owner daemon.
- **One active turn per conversation:** the rule that makes turn diffs
  attributable at all.

## 5. Spike plan

### 5.1 Questions

- **Q1. View cost.** Create, first `git status`, fork and discard time, and
  disk use, per provider. Does cloning ever stall the operator's checkout?
- **Q2. Toolchains in a clone at a new path.** Does each work, rebuild or
  break: Go, npm/node, SwiftPM `.build`, Gradle, Xcode DerivedData, Python
  venv shebangs, CMake caches? Is any of them silently cross-contaminated
  (for example, a venv in the view that still runs the base's interpreter)?
- **Q3. Overlay at the original path.** Do git, node, go, Codex and Claude
  run unmodified? How often do directory renames hit `EXDEV`? What is the
  copy-up false-positive rate?
- **Q4. Recorder exactness.** Do the shadow snapshot and the ignored
  manifest match the oracle for every scenario and both harnesses?
- **Q5. Harness reports.** Measure their recall and precision against the
  oracle.
- **Q6. Snapshot latency.** p50 and p95 per turn and per tool call.
- **Q7. Git mapping.** Can we publish, merge and preview conflicts from
  snapshots without touching the operator's checkout, including when agents
  commit or switch branches themselves?
- **Q8. Path-keyed state.** What do Codex and Claude write per view path, and
  do `CODEX_HOME`, `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_PROJECT_DIR_NAME`
  contain it?

### 5.2 Layout

**Code.** `tools/spikes/workspaces/`, a nested Go module, so `go test ./...`,
lint and CI in the main module are unaffected. Phases A–C wire nothing into the
daemon.

**Hosts.**

- **macOS:** `/Volumes/External/dieter-spike/`. It is APFS with 709 GiB
  free. The Data volume is 98% full (4.1 GiB free), and the repository and
  its views must share one volume.
- **Linux:** `garuda:~/dieter-spike/` (btrfs, kernel 6.18, bubblewrap 0.12,
  git 2.55, codex and claude installed), driven through `dieter remote exec`.

**Components.**

1. **`fixture`** builds deterministic repositories:
   - Profiles: `small` (2k files), `js` (5k tracked plus a 40k-file ignored
     `node_modules`), `huge` (150k entries), plus a copy of this repository.
   - Contents: text and binary files, an executable bit, a symlink, NFC and
     NFD names, a case-variant pair, `.env`, `build/`, `gen/` and a 50 MiB
     file.
2. **`view`** providers: `worktree`, `worktree+hydrate`, `apfs-clone(a)`,
   `apfs-clone(b)`, `overlay`, `btrfs-snapshot` and `reflink`.
3. **`oracle`** is a full walk that uses no git: lstat for every entry, plus
   SHA-256 for regular files, symlink targets, mode, type and xattr names.
   Its before/after diff is the ground truth for judging the recorders.
4. **`record`** recorders:
   - `shadow-snapshot`
   - `ignored-manifest`
   - `clone-id-scan`
   - `overlay-upper`
   - `fsevents-hint`
   - `harness-codex`: app-server `item/*` and `turn/diff/updated`
   - `harness-claude`: `tool_use_result`, plus `PostToolUse` with
     `bashEditDiffEnabled`
5. **`drive`** drivers:
   - `script` runs a scenario's steps directly. It needs no LLM, defines the
     expected result and can run in CI.
   - `codex` runs `codex app-server --stdio` with Dieter's settings:
     `danger-full-access`, `approval_policy=never`, `cwd` set to the view.
   - `claude` runs the Agent SDK `query()` with `cwd` set to the view and
     `bypassPermissions`.
   - Use the versions pinned in `internal/harness/runtime/package.json`:
     Codex 0.163.0 and Agent SDK 0.3.303.
   - Prompts are scripted: "Perform exactly these steps, using the tool named
     for each." The tool column forces edit-tool versus shell paths.
6. **`report`** writes JSONL per run and a Markdown matrix: scenario ×
   harness × recorder, with TP/FP/FN counts, timings and disk use.

### 5.3 Scenario catalog

| ID  | Step                                                                              | Stresses                                              |
| --- | --------------------------------------------------------------------------------- | ----------------------------------------------------- |
| S01 | Edit a tracked file with the native edit tool                                     | baseline; harness reports should be correct           |
| S02 | Create a new file with the edit tool                                              | untracked, not ignored                                |
| S03 | `sed -i` on a tracked file                                                        | shell edit (Codex misses it)                          |
| S04 | Write a new file with a heredoc or `python3 -c`                                   | shell create                                          |
| S05 | `rm` a tracked file                                                               | delete (overlay whiteout)                             |
| S06 | `mv` / `git mv` a file                                                            | rename                                                |
| S07 | `mv dir dir2`                                                                     | directory rename (overlay `EXDEV`)                    |
| S08 | `chmod +x`                                                                        | mode-only change                                      |
| S09 | `touch`; rewrite a file with identical content                                    | false positives (copy-up, clone-id)                   |
| S10 | Create and retarget a symlink                                                     | type changes                                          |
| S11 | Write 1 MiB and 50 MiB binaries                                                   | size limits, snapshot cost                            |
| S12 | Run a formatter (`gofmt -w`) over many files                                      | bulk shell edits                                      |
| S13 | Codegen into ignored `gen/` and tracked `api/`                                    | mixed ignored and tracked                             |
| S14 | Extract a dependency tarball into `node_modules` (10k files)                      | ignored bulk; manifest cost                           |
| S15 | Edit `.env`                                                                       | ignored, sensitive: hash only, never content          |
| S16 | `git commit -am`, then more edits                                                 | HEAD moves inside the view                            |
| S17 | `git checkout -b x`; `git stash`; `git stash pop`                                 | tree-moving git operations (Claude reports `skipped`) |
| S18 | `mv Readme.md README.md`                                                          | case-only rename on case-insensitive APFS             |
| S19 | Create an NFD name, then the same name in NFC                                     | Unicode normalization                                 |
| S20 | `(sleep 5; echo late > late.txt) &`, then end the turn                            | late writer goes to the "background" bucket           |
| S21 | Write to a spike-owned sentinel outside the view, and to the base checkout's path | escape detection                                      |
| S22 | `ln a b` (hard link)                                                              | the clone splits hard links                           |
| S23 | `xattr -w` / `setfattr` only                                                      | xattr-only change                                     |
| S24 | `rm -rf build/` (ignored)                                                         | ignored delete                                        |
| S25 | A Claude subagent edits; a turn makes several tool calls                          | subagent coverage; per-tool-call snapshots            |

### 5.4 Experiments

- **E1. View cost**, providers × fixtures:
  - create, first `git status`, fork and discard time
  - disk use (`ATTR_CMNEXT_PRIVATESIZE`, change in `df`)
  - stall test: a writer loop in the clone source logs its maximum write
    latency while a clone runs
- **E2. Toolchains in views.**
  - macOS, on a view of this repository: `go build ./...`, `just build`,
    `swift build` in `native/macos`, and `npm ci` of the harness runtime.
  - Linux: `go build` and node.
  - Record works, rebuilds or breaks for each, and how much is rebuilt.
- **E3. Recorder accuracy** with the script driver: all scenarios ×
  providers × recorders, against the oracle.
- **E4. Real harnesses.** Run E3's scenarios through Codex and through
  Claude, two repeats each, at low reasoning effort, about 100 short turns
  in total. Record harness-reported changes against the oracle.
- **E5. Concurrency.**
  - Three conversations (two Codex, one Claude) run in parallel views of one
    checkout and touch overlapping files. Expect zero writes across views.
  - Publish all three as branches and preview the conflicts.
  - Fork one view mid-session and continue both copies.
- **E6. Snapshot cost** per turn and per tool call, on this repository and
  the `js` and `huge` fixtures, with and without FSMonitor and the untracked
  cache.
- **E7. Path-keyed state.** Compare temporary `CODEX_HOME` and
  `CLAUDE_CONFIG_DIR` before and after creating N views. Try
  `CLAUDE_CODE_PROJECT_DIR_NAME`. On Linux, check for collisions at the same
  path.
- **E8 (optional, timeboxed to 1 day).** Run Apple's FSKit passthrough sample
  on macOS 27: can it be enabled and mounted as a user? Then run S01–S24
  through it. This decides whether a macOS overlay track is worth starting
  in 2027.

### 5.5 Phases

| Phase | Days | Work                                                                                                                                                                                                                                                                                            | Experiments  |
| ----- | ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| A     | 1.5  | Fixture, oracle, script driver and shadow recorder; `apfs-clone` (a, b), `worktree` and `worktree+hydrate` on macOS                                                                                                                                                                             | E1, E3 macOS |
| B     | 1.5  | `overlay` with a btrfs base on garuda; ignored manifest and upper-walk recorders                                                                                                                                                                                                                | E1–E3 Linux  |
| C     | 2    | Codex and Claude drivers with harness-report recorders                                                                                                                                                                                                                                          | E4, E5, E7   |
| D     | 1    | Put the best provider and the turn snapshots behind a spike flag in a temporary `DIETER_HOME`: `provision` in `internal/git/workspace/manager.go`, plus `T_start`/`T_end` hooks in `turn_admission.go`/`turn_execution.go`. Run a real card through the fixture gateway on a free loopback port | E2, E6       |
| E     | 0.5  | Results report and ADR drafts                                                                                                                                                                                                                                                                   |              |
| (E8)  | +1   | FSKit probe                                                                                                                                                                                                                                                                                     | E8           |

### 5.6 Decision gates

- **G1, clone viability.** From a base, `apfs-clone` creates a view in at
  most 2 s for 25k entries and at most 15 s for 150k, with no measurable
  stall of the operator's checkout. Otherwise use `worktree+hydrate`.
- **G2, exactness.** On the shadow snapshot plus the ignored manifest, with
  content-hash filtering:
  - S01–S19 and S22–S24 reach 100% recall and 100% precision against the
    oracle;
  - S20 lands in the background bucket;
  - S21 is flagged as an escape.

  Otherwise document every gap before going further.

- **G3, cost.** Snapshot p95 is at most 500 ms per turn on this repository
  and at most 1 s on `js`. Otherwise snapshot per turn only, never per tool
  call.
- **G4, Linux overlay.** Every scenario passes, directory-rename fallback
  behaviour is acceptable, and both harnesses run unmodified. Otherwise
  views use btrfs snapshots or reflink copies.
- **G5, toolchains.** No silent cross-contamination. Every breakage has a
  fix, such as excluding a directory from the clone and recreating it.
- **G6, agent state.** Per-view config and transcript entries are contained,
  or cleaned up deterministically.

### 5.7 Safety

- **The operator's setup.** Never touch the running daemon, `Dieter.app` or
  the operator's `DIETER_HOME`. Phase D uses a temporary `DIETER_HOME`, a
  free non-default loopback port and the fixture gateway.
- **Spike data.** It lives only under `/Volumes/External/dieter-spike` and
  `garuda:~/dieter-spike`. A cleanup script `chmod`s overlay work
  directories before removing them.
- **The escape scenario (S21)** targets only spike-owned sentinel paths.
- **Agents** run with full access, as Dieter runs them today, but only in
  scratch repositories.
- **Codex and Claude config homes.** Their path-keyed state is written to
  temporary config homes, which need credentials; this is open question 1.

### 5.8 Deliverables

- The spike tool in `tools/spikes/workspaces` (a nested Go module).
- `docs/proposals/agent-workspaces-results.md` with the matrices and timings.
- ADR drafts:
  1. view providers and per-volume clone roots;
  2. the per-turn change record and shadow store;
  3. Linux namespace views versus "without a sandbox".

## 6. Open questions

1. ~~**Credentials for the spike's harness runs.**~~ Resolved: copies, with the
   Codex refresh token neutered and only the Claude access token passed.
2. **Where a view starts.** From the base ref (worktree-like: run
   `git checkout --detach <base>` in the clone, which rewrites only the files
   that differ) or from the operator's dirty tree (project-like)? It is
   probably a per-card choice.
3. **Terminals and `dieter remote exec` for a card** must enter the same
   view. On macOS that is just the cwd. On Linux it needs a namespace holder
   process plus `nsenter`.
4. **Alternates risk.** If the project repository runs gc after a rebase, it
   can prune base objects that shadow snapshots still reference. Either
   fetch base commits into the shadow store or keep retention short.
5. **Is variant (a), with its own `.git`, worth reworking
   `internal/git/operations`**, or is variant (b) enough?

## Sources

- LayerFS:
  [repository](https://github.com/Ephemeral-AI-Lab/layerfs),
  [limits](https://github.com/Ephemeral-AI-Lab/layerfs/blob/main/core/docs/architecture/06-limits.md),
  [mount session](https://github.com/Ephemeral-AI-Lab/layerfs/blob/main/core/docs/architecture/76-native-mount-session.md),
  [known limits](https://github.com/Ephemeral-AI-Lab/layerfs/blob/main/docs/versioned/0.1.7/sdk-and-ui.md#7-known-limits)
- APFS: `man 2 clonefile`, `man 2 getattrlistbulk`;
  [DTS on directory clones](https://developer.apple.com/forums/thread/784446);
  [snapshot entitlement](https://developer.apple.com/forums/thread/89635)
- FSKit:
  [passthrough sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system),
  [27.0 bug list](https://developer.apple.com/forums/thread/842736),
  [enablement](https://developer.apple.com/forums/thread/808594),
  [no process attribution](https://developer.apple.com/forums/thread/766793);
  [macFUSE backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends);
  [FUSE-T](https://github.com/macos-fuse-t/fuse-t);
  [go-nfs](https://github.com/willscott/go-nfs);
  [EdenFS on macOS](https://github.com/facebook/sapling/blob/main/eden/fs/docs/macOS.md)
- Linux:
  [overlayfs](https://docs.kernel.org/filesystems/overlayfs.html),
  [overlayfs params.c](https://github.com/torvalds/linux/blob/master/fs/overlayfs/params.c),
  [bubblewrap](https://github.com/containers/bubblewrap),
  [Landlock](https://docs.kernel.org/userspace-api/landlock.html),
  [fanotify_init(2)](https://man7.org/linux/man-pages/man2/fanotify_init.2.html),
  [FUSE backing.c](https://github.com/torvalds/linux/blob/master/fs/fuse/backing.c)
- Harnesses:
  [Codex turn_diff_tracker.rs @ 0.163.0](https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/core/src/turn_diff_tracker.rs),
  [Codex ghost snapshot removal](https://github.com/openai/codex/pull/19481),
  [Claude Code checkpointing](https://code.claude.com/docs/en/checkpointing),
  [Claude Code worktrees](https://code.claude.com/docs/en/worktrees),
  [Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing),
  [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)
- Prior art:
  [AgentFS overlay](https://turso.tech/blog/agentfs-overlay),
  [AgentFS #333](https://github.com/tursodatabase/agentfs/issues/333),
  [GitButler parallel agents](https://docs.gitbutler.com/ai-agents/parallel-agents),
  [GitButler PR #13850](https://github.com/gitbutlerapp/gitbutler/pull/13850),
  [jj working copy](https://docs.jj-vcs.dev/latest/config/),
  [container-use](https://github.com/dagger/container-use),
  [Codex worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees),
  [The story of Scalar](https://github.blog/open-source/git/the-story-of-scalar/)
