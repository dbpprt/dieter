# Spike results: copy-on-write agent workspaces with exact change records

Status: spike completed 2026-10-21 · plan: [agent-workspaces.md](agent-workspaces.md) ·
code: [`tools/spikes/workspaces`](../../tools/spikes/workspaces/README.md) · raw summaries:
[`tools/spikes/workspaces/results`](../../tools/spikes/workspaces/results)

## TL;DR

The design holds, with five corrections.

- **Views work on both platforms.**
  - **macOS: APFS clones.** One `clonefile` from a Dieter-owned base creates a
    full view in 0.2 s for 3.5k entries, 1.9 s for 55k and 9.5 s for 175k,
    ignored files included. A git worktree of the same 175k-entry repository
    took 16.7 s to check out and still had no `node_modules`.
  - **Linux: overlayfs.** An unprivileged overlay mounted at the checkout's
    own path costs nothing to create, and the first `git status` takes
    8–52 ms.
  - **Linux: btrfs snapshots.** A snapshot view takes 3–13 ms for any size.
- **The record is exact.** We compared it with an oracle that hashes every
  file before and after each turn. The pairing is:
  - **macOS:** a shadow-git snapshot for tracked files plus a stat-cached
    manifest for ignored files: 0 misses and 0 false positives over 21,452
    true changes.
  - **Linux:** a read of the overlay upper directory, also exact. It saw all
    21,450 changes in real Codex and Claude runs, with no misses and no false
    positives.
- **Harness reports cannot be the record.** Against git-scope truth:
  - Codex 0.163 reported **14 of 1,266** changes (1.1%), namely only its
    `apply_patch` edits.
  - Claude Code 2.1.303 reported **862 of 1,270** (68%), and only with
    `bashEditDiffEnabled` forced on. It missed directory moves, case-only
    renames and xattr changes.
  - Neither reported a false positive.
- **Dieter integration works end to end.** A patched isolated daemon ran
  real Claude and Codex cards in clone-populated worktrees:
  - the per-turn record caught every shell edit (snapshot 249–295 ms);
  - Dieter's existing changes, stage, commit and `merge_local` worked
    unchanged.
- **Corrections to the plan:**
  1. Clones break path-bound tool state. A Python venv in the view runs the
     **source checkout's** pip through its absolute shebang. A CMake build
     directory silently stops rebuilding view edits.
  2. A git worktree filled by clones (variant b) needs per-worktree
     `core.checkStat=minimal`/`core.trustCtime=false`. Without them the first
     `git status` rehashes everything: 11.5 s against 0.85 s on 175k
     entries.
  3. Overlay remounts race. overlayfs releases its upper-directory lock
     asynchronously, so remounting right away fails with `EBUSY`. Use one
     long-lived namespace per session, or retry.
  4. The recorder must merge git with the manifest. Git cannot see
     case-only renames on case-insensitive APFS or xattr-only changes; the
     manifest sees both.
  5. Path-keyed agent state grows per view on macOS: one Claude
     `projects/<slug>` directory per clone path (52 for 52 sessions).

## Setup

|           | macOS                                                                                                                                                                                                       | Linux                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Host      | Mac mini, macOS 27.0 (26A428), APFS external SSD `/Volumes/External` (slow: about 5 ms per file create)                                                                                                     | `garuda`: Garuda Linux, kernel 6.18 LTS, btrfs `/home`, bubblewrap 0.12.0, git 2.55 |
| Harnesses | Codex 0.163.0 (`gpt-6-astra`, effort low) via `codex app-server`, Dieter's settings; Claude Agent SDK 0.3.303 / Claude Code 2.1.303 (`claude-sonnet-5-5`), `bypassPermissions`, `bashEditDiffEnabled: true` | same versions, installed with npm                                                   |
| Fixtures  | `small` (1k tracked + 2k ignored), `js` (5k + 40k), `huge` (50k + 100k): deterministic git repositories with `node_modules`, `build/`, `.env`, symlinks, a hard-link pair and NFC/NFD names                 | the same generator, as btrfs subvolumes                                             |

**Credentials.** Each harness got a temporary `CODEX_HOME` or
`CLAUDE_CONFIG_DIR`:

- **Codex:** `auth.json` with the refresh token replaced by a dummy value,
  so the copy could never rotate it.
- **Claude:** only the access token, passed through
  `CLAUDE_CODE_OAUTH_TOKEN`; the refresh token was never copied.

All copies were deleted after the runs. The operator's `~/.codex`,
`~/.claude` and keychain items were not modified.

**Scale.** The 26 scenarios
([catalog](../../tools/spikes/workspaces/scenarios/scenarios.go)) ran with:

- the script driver on every view provider;
- Codex and Claude twice each on macOS clones and on Linux overlays,
  216 real agent turns in total.

Every row compares the recorders and the harness report with an oracle: a
full walk that hashes every file and uses no git.

## 1. Recorder accuracy (Q4)

The table sums true changes over all turns and late windows. "Git scope" means
paths git does not ignore.

| Platform · view · driver                  | Recorder                | All paths TP/FP/FN | Git scope TP/FP/FN | p50 / p95 ms |
| ----------------------------------------- | ----------------------- | ------------------ | ------------------ | ------------ |
| macOS · clone · script                    | manifest                | 10,726 / 0 / 0     | 635 / 0 / 0        | 30 / 68      |
|                                           | shadow (git)            | 632 / 0 / 10,094   | 632 / 0 / **3**    | 240 / 453    |
|                                           | clonescan (stat only)   | 10,726 / 3 / 0     | 635 / 3 / 0        | 21 / 55      |
|                                           | FSEvents replay         | 10,326 / 204 / 400 | 235 / 204 / 400    | 76 / 221     |
| macOS · clone · Codex ×2                  | manifest                | 21,348 / 0 / 0     | 1,266 / 0 / 0      | 33 / 99      |
|                                           | shadow                  | 1,260 / 0 / 20,088 | 1,260 / 0 / **6**  | 303 / 577    |
|                                           | **Codex-reported**      | 14 / 0 / 21,334    | **14 / 0 / 1,252** | –            |
| macOS · clone · Claude ×2                 | manifest                | 21,452 / 0 / 0     | 1,270 / 0 / 0      | 36 / 106     |
|                                           | shadow                  | 1,264 / 0 / 20,188 | 1,264 / 0 / **6**  | 277 / 623    |
|                                           | **Claude-reported**     | 862 / 0 / 20,587   | **862 / 0 / 405**  | –            |
| Linux · overlay · Codex ×2                | upper dir               | 21,350 / 0 / 0     | 1,268 / 0 / 0      | 0 / 21       |
|                                           | shadow (from the upper) | 1,264 / 0 / 20,086 | 1,264 / 0 / 4      | 6 / 26       |
|                                           | **Codex-reported**      | 14 / 0 / 21,336    | **14 / 0 / 1,254** | –            |
| Linux · overlay · Claude ×2               | upper dir               | 21,450 / 0 / 0     | 1,268 / 0 / 0      | 0 / 22       |
|                                           | **Claude-reported**     | 866 / 0 / 20,584   | **866 / 0 / 402**  | –            |
| Linux · btrfs, reflink, worktree · script | manifest                | 10,726 / 0 / 0     | 635 / 0 / 0        | 1–3          |

Every remaining miss has a known cause:

- **Shadow, macOS S18 (case-only rename, `Readme.md` → `README.md`).** On
  case-insensitive APFS, git (`core.ignorecase=true`) still sees `Readme.md`
  and records no change. The manifest records a delete plus an add.
  Publishing therefore has to apply case renames explicitly.
- **Shadow, S23 (xattr-only change).** Git does not track xattrs; the
  manifest does.
- **Shadow from the upper, Linux S19 (NFD name).** This was a bug in the
  spike: NFC normalisation broke the content lookup. Fixed, and the re-run
  came out clean. The Codex overlay matrix ran before the fix.
- **clonescan.** It compares stats without hashing. `touch` and the source of
  a new hard link change ctime, which gives 3 false positives. Clone ids
  change only on the first write after a clone, not on later writes, so they
  cannot mark per-turn changes on their own.
- **FSEvents.** Temporary files (`sed -i` → `.!NNN!file`, `perl -pi`) show up
  as extra paths. A directory rename arrives as one directory event, which
  accounts for the 400 misses. A replay started immediately after the writes
  can also miss events that are still in flight: the event-id barrier taken
  at call time does not cover them. That happened in 1 of 4 unit-test runs,
  so callers need a settle delay or a marker write. It is fine as a hint and
  for escape detection; it cannot be the record.

**Late writers and escapes.**

- **S20 (`(sleep 5; …) &`).**
  - **Claude:** the job wrote after the turn ended, and the late window
    caught it in every recorder.
  - **Codex:** it kills a command's background jobs when the command
    returns, so nothing was written late.
  - **Linux overlay:** the per-turn PID namespace (`--unshare-pid`) kills
    background jobs by construction.
- **S21 (writes outside the view).**
  - **macOS:** FSEvents replay on the operator's checkout and on a sentinel
    directory flagged both writes.
  - **Linux overlay:** the write to the checkout path lands in the
    session's own upper directory, so it is captured, not escaped. Only the
    sentinel write outside the checkout reached the host.

## 2. What the harnesses report (Q5)

Each cell is reported/true over two repetitions, in git scope, on macOS. Linux
matches, except that Claude reported S18 fully there because Linux is
case-sensitive.

| Scenario                                                      | Claude          | Codex        |
| ------------------------------------------------------------- | --------------- | ------------ |
| S01/S02 edit tool modifies or creates                         | ✓               | ✓            |
| S03 `sed -i`, S04 shell creates, S05 `rm`, S06 `mv`           | ✓               | ✗            |
| S07 `mv dir dir2` (200 files)                                 | partial 400/800 | ✗ 0/800      |
| S08 `chmod +x`, S10 symlinks, S11 binaries, S22 hard link     | ✓               | ✗            |
| S12 `perl -pi` over 200 files                                 | ✓ 400/400       | ✗ 0/400      |
| S13 codegen, S16 agent commit then edit, S17 branch and stash | ✓               | ✗            |
| S18 case-only rename (APFS)                                   | partial 2/4     | ✗            |
| S23 xattr only                                                | ✗               | ✗            |
| S25 three edits plus three shell commands                     | ✓ 12/12         | partial 6/12 |
| Ignored paths (`node_modules`, `.env`, `build/`)              | never           | never        |

- **Codex:** its `fileChange` items and `turn/diff/updated` contain only
  `apply_patch` edits, so every shell edit is invisible.
- **Claude:** its `bashEditDiff` coverage is good when forced on. It is
  git-tracked only and capped at 200 paths, and it is behind a rollout gate
  in Dieter's normal `bypassPermissions` mode.

Both are useful for live UI hints. Neither can be the record.

## 3. View cost (Q1)

All figures are medians of three runs. The macOS volume is a slow external
SSD, so absolute numbers are pessimistic; compare the rows.

| Fixture (entries)   | Provider                               | Create  | First `git status` | Discard                             | Disk used |
| ------------------- | -------------------------------------- | ------- | ------------------ | ----------------------------------- | --------- |
| small (3.5k), macOS | clone (view config)                    | 0.20 s  | 0.08 s             | 0.8 s                               | 1 MB      |
|                     | clone, no config                       | 0.11 s  | 0.32 s             | 0.7 s                               | 1 MB      |
|                     | worktree (today)                       | 0.79 s  | 0.17 s             | 0.3 s                               | 4.5 MB    |
| js (55k), macOS     | clone (view config)                    | 1.86 s  | 0.12 s             | 11.3 s                              | 16 MB     |
|                     | clone-worktree (variant b)             | 1.82 s  | **1.18 s**         | 11.4 s                              | 17 MB     |
|                     | worktree (no `node_modules`)           | 1.72 s  | 0.23 s             | 0.8 s                               | 22 MB     |
|                     | worktree + clone-hydrated ignored dirs | 3.64 s  | 0.22 s             | 11.0 s                              | 36 MB     |
| huge (175k), macOS  | clone (view config)                    | 9.49 s  | 0.85 s             | 40.7 s                              | 52 MB     |
|                     | clone, no config                       | 7.52 s  | **13.96 s**        | 34.6 s                              | 52 MB     |
|                     | clone-worktree (variant b)             | 7.76 s  | **11.54 s**        | 36.4 s                              | 51 MB     |
|                     | worktree (no ignored files)            | 16.72 s | 0.45 s             | 8.7 s                               | 220 MB    |
|                     | worktree-hydrate                       | 23.55 s | 0.49 s             | 36.7 s                              | 257 MB    |
| huge (175k), Linux  | overlay                                | 0       | 0.05 s             | 0                                   | –         |
|                     | btrfs snapshot                         | 0.01 s  | 0.05 s             | 1.9 s (unprivileged delete is O(n)) | –         |
|                     | reflink copy                           | 1.84 s  | 0.42 s             | 1.2 s                               | –         |
|                     | worktree                               | 0.62 s  | 0.18 s             | 0.3 s                               | –         |

Two more findings:

- **Discard is the slow half of a clone.** Deleting is 4–6× slower than
  creating, so discard must rename into a trash directory and delete in the
  background.
- **A directory clone is atomic but not point-in-time.** In the stall test,
  the source's writers were not blocked, yet files written during the clone
  ended up in it, some of them half-written. Clone only from a quiescent base,
  never from the live checkout or a running view.

## 4. Snapshot cost per turn (Q6)

Median ms per mark by the number of tracked files modified in the turn:

| Host · fixture            | Recorder                           | 0               | 10              | 100            | 1,000           |
| ------------------------- | ---------------------------------- | --------------- | --------------- | -------------- | --------------- |
| macOS external SSD · js   | shadow                             | 239             | 275             | 517            | 3,290           |
|                           | manifest / clonescan / FSEvents    | 490 / 347 / 115 | 547 / 326 / 211 | 677 / 452 / 72 | 711 / 475 / 103 |
| macOS external SSD · huge | shadow                             | 495             | 565             | 909            | 3,083           |
|                           | manifest                           | 1,494           | 1,305           | 1,585          | 1,425           |
| Linux btrfs · huge        | shadow / manifest                  | 18 / 145        | 39 / 134        | 41 / 121       | 81 / 117        |
| Linux overlay · huge      | shadow from the upper / upper read | 23 / 0          | 49 / 0          | 77 / 1         | 349 / 8         |

- **This repository on the internal SSD:** 0.16–0.25 s (measured while
  writing the plan).
- **Shadow cost grows with the change set** because each new blob is a loose
  object. On the slow disk, 1,000 changed files cost about 3 s.
- **What that means:**
  - Snapshot once per turn everywhere.
  - Per-tool-call snapshots are affordable on Linux.
  - Large change sets should be written as a pack (`git fast-import`), not
    as loose objects.

## 5. Toolchains in a view (Q2)

| Tool                               | macOS clone at a new path                                                                                                           | Linux btrfs clone at a new path | Linux overlay at the same path        |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- | ------------------------------------- |
| Go                                 | builds; rebuilds the module's packages once per new path (cache key includes the directory)                                         | same                            | cache hits, no rebuild                |
| SwiftPM                            | builds, and picks up an edit made in the view                                                                                       | –                               | –                                     |
| npm (`node_modules`, `.bin` links) | works                                                                                                                               | works                           | works                                 |
| Python venv                        | **unsafe:** `.venv/bin/pip` shebang points at the **source** venv, so `pip install` in the view modifies the operator's environment | **unsafe**, same cause          | works (the path resolves to the view) |
| CMake build dir                    | **silently stale:** `cmake --build` exits 0 and does not rebuild the view's edited `main.c` (it tracks the source path)             | – (CMake not installed)         | works (same path)                     |

**Rule for clone views:** exclude path-bound directories (`.venv`, CMake/Bazel
build directories, anything with absolute paths baked in) from the clone and
recreate them, or fall back to an overlay. Gate G5 fails for clones as they
stand, and the fix is a per-project exclude list.

## 6. Concurrency, fork and publish (Q7)

|                                       | macOS clones                                                                                                                                    | Linux overlays (same path, separate namespaces)                |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Sessions                              | 2 Codex + 1 Claude in parallel, overlapping edits                                                                                               | same                                                           |
| Cross-session writes                  | none                                                                                                                                            | none                                                           |
| Operator checkout touched             | no                                                                                                                                              | no                                                             |
| Fork after turn 1                     | 110 ms (clone of the view); diverged independently                                                                                              | about 0 ms (reflink copy of the upper); diverged independently |
| Publish                               | each session as `dieter/spike-N`: squash `commit-tree` of the final snapshot, fetched from the shadow repository, compare-and-swap `update-ref` | same                                                           |
| `git merge-tree --write-tree` preview | conflicts on `docs/guide.md` and `src/app/main.go` for every pair, as designed                                                                  | same                                                           |

**Overlay `EBUSY`.** Mounting the same upper directory again straight after
a session exits fails with `EBUSY` until the kernel finishes tearing down
the old mount, about 2 s later. A retrying launcher
(`spike bwrap-retry`) fixed the fork. A product implementation should keep
one long-lived namespace per session and enter it for each turn.

## 7. Path-keyed agent state (Q8)

- **Claude Code** writes one `projects/<path-slug>` directory per working
  directory, plus `/tmp/claude-<uid>/<slug>`:
  - **macOS clones:** 52 project directories for 52 sessions.
  - **Linux overlay, same path:** one shared directory for all 53 sessions.
    Resuming by session ID still works.
  - **Mitigation:** set `CLAUDE_CODE_PROJECT_DIR_NAME` and
    `CLAUDE_CODE_TMPDIR` per card, or clean up.
- **Codex** was expected to add one `[projects."<path>"]` trust entry per
  view. Instead, a single entry survived after about 57 sessions in one
  shared `CODEX_HOME`. That points to last-writer-wins rewrites of
  `config.toml`; the root cause is unverified. A per-card `CODEX_HOME`, or
  writing the trust entry up front, avoids both the growth and the race.

## 8. Dieter integration (Phase D)

The patch is env-gated and saved as
[`daemon/phase-d.patch`](../../tools/spikes/workspaces/daemon/phase-d.patch).
It was reverted from the tree afterwards and still applies cleanly.

**What it adds:**

- **`DIETER_SPIKE_WORKSPACE_VIEW=clone`:** worktree mode runs
  `git worktree add --no-checkout`, clones the project's top-level entries
  in (including ignored ones), seeds the index, and runs
  `git -c core.checkStat=minimal -c core.trustCtime=false reset --hard`.
  View creation took 0.48 s on the small fixture.
- **`DIETER_SPIKE_TURN_SNAPSHOTS=1`:** a snapshot right after
  `Workspaces.Ensure` (turn start) and in the turn's `finish` before
  `Refresh` (turn end), stored in a shadow repository under
  `DIETER_HOME/spike`. The turn's change set is written to
  `DIETER_HOME/spike/turns/<card>/<turn>.json`.

**What happened on the real cards** (isolated daemon, fixture project):

- **Claude card:** the worktree contained `node_modules`, `build/` and
  `.env` with no install step.
  - Record: `D Makefile`, `M docs/guide.md`, `A notes.txt`,
    `M src/app/main.go` (249 ms). Three of the four were shell edits.
  - Then `workspace changes`, `stage`, `commit` and `merge_local` ran
    unchanged and merged into `main`.
- **Codex card:** the record matched `git status` exactly:
  `D api/schema.json`, `M docs/guide.md`, `A notes-codex.txt`,
  `M src/app/main.go` (295 ms).
- **Unrelated finding:** the first turn of a brand-new `DIETER_HOME` stalled
  ("agent worker stopped reporting progress") while `npm ci` installed the
  harness runtime. Resending worked.

## 9. Committing and pushing from a view

Verified after the main runs against a local bare `origin` (fixture `small`).

| View                                                    | Where an agent's `git commit` lands                                                                        | How it reaches `origin`                                                                                                                                                                                                                                                            | Verified                                                                                                                                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS, registered worktree filled by clones (variant b) | The project repository, on `dieter/<card>`, exactly like a worktree today                                  | `git push origin dieter/<card>` from the view or through Dieter's `push` and `create_pr` operations; the branch is visible in the project immediately                                                                                                                              | Pushed. First `git status` took 192 ms with `extensions.worktreeConfig` plus per-worktree `core.checkStat=minimal` and `core.trustCtime=false`. The main checkout's config stayed unchanged. |
| macOS, full clone including `.git` (variant a)          | The clone's own `.git` (the agent committed onto its private `main`); the project does not have the commit | **Pull:** `git -C <project> fetch <view> HEAD:refs/heads/dieter/<card>` copies only the new objects, then push from the project. A direct `git -C <view> push origin HEAD:refs/heads/dieter/<card>` also works, but it bypasses Dieter's serialized operations.                    | Both pushed                                                                                                                                                                                  |
| Linux overlay at the checkout path                      | The session's upper directory (12 files under `.git`); the host repository is untouched                    | Inside the session: `git push origin …` works when the remote lives outside the checkout. Or bind the real checkout at a second path (`--bind <checkout> <alt>`) and run `git push <alt> HEAD:refs/heads/dieter/<card>`; the branch then exists on the host and pushes from there. | Both pushed                                                                                                                                                                                  |
| Any view, no agent commit                               | Nothing; Dieter builds the commit                                                                          | Squash `commit-tree` of the last turn snapshot onto the base, fetch it from the shadow repository, then a compare-and-swap `update-ref` (§6)                                                                                                                                       | Published (§6)                                                                                                                                                                               |

## Gate verdicts

| Gate                | Verdict                                                                                                                                                                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1: clone viability | **Pass.** 1.9 s for 55k entries and 9.5 s for 175k, from a base. Not point-in-time, so a quiescent base is required.                                                                                      |
| G2: exactness       | **Pass** for shadow plus manifest (macOS) and the upper read (Linux): 0 FP and 0 FN overall. Late writes are bucketed. Escapes are detected on macOS; on Linux they are impossible for the checkout path. |
| G3: cost            | **Pass per turn** (≤ 0.6 s p95 for typical turns). Per tool call only on Linux or fast disks; 1,000-file turns cost about 3 s on a slow disk.                                                             |
| G4: Linux overlay   | **Pass with one change:** a long-lived namespace or a retry for the `EBUSY` remount race.                                                                                                                 |
| G5: toolchains      | **Fail for clones as they stand** (venv, CMake). Needs an exclude-and-recreate list. Overlays pass.                                                                                                       |
| G6: agent state     | **Partial.** Claude directories grow per clone path, and Codex trust entries race. Needs per-card config homes or project directory names.                                                                |

## Follow-up

macOS has no way to give a session a private view at the original path. The
options and a path-safe design are in
[agent-workspaces-macos.md](agent-workspaces-macos.md).

## Recommended next steps

1. **ADR 1, views.**
   - **macOS:** start with variant (b), a registered worktree filled by
     clones from a Dieter-owned base with `extensions.worktreeConfig`
     check-stat settings. Every existing git operation kept working.
   - **Linux:** an overlay at the checkout path, inside a long-lived session
     namespace.
   - **Both:** a per-project exclude-and-recreate list for path-bound
     directories, and a clone root on the checkout's own volume.
2. **ADR 2, the turn record.**
   - A shadow repository under `DIETER_HOME`, plus a manifest for ignored
     paths (or the overlay upper), with snapshots at turn start and end.
   - Expose the per-turn change set in `ConversationTurn` and on the
     Changes surface.
   - Harness reports stay live hints only.
3. **ADR 3, Linux namespaces** versus the "without a sandbox" invariant.
4. **Pass per-card harness state:** `CLAUDE_CODE_PROJECT_DIR_NAME`,
   `CLAUDE_CODE_TMPDIR` and a per-card or pre-trusted `CODEX_HOME`.
