# Agent workspace spike

Spike code for [docs/proposals/agent-workspaces.md](../../../docs/proposals/agent-workspaces.md).
Results: [docs/proposals/agent-workspaces-results.md](../../../docs/proposals/agent-workspaces-results.md).

This is a nested Go module (`dieter.spike/workspaces`), so `go test ./...`,
lint and CI in the main module do not see it. It is evidence, not product
code.

## Packages

| Package                 | Contents                                                                                                                                                                          |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `core`                  | Shared types: trees, change sets, scoring, scenario steps, the driver contract, prompt rendering                                                                                  |
| `tree`                  | Fixture generator, the oracle (a full walk that hashes every file and uses no git) and a stat-cached manifest                                                                     |
| `darwinfs`              | APFS `clonefile`, a `getattrlistbulk` clone-id scanner, FSEvents history replay (cgo)                                                                                             |
| `linuxfs`               | bwrap overlay launcher, upper-directory reader and diff, reflink copies, btrfs subvolumes                                                                                         |
| `shadow`                | Shadow-git snapshots (private index, alternates), diffs, publish, `merge-tree` preview                                                                                            |
| `views`                 | View providers: `clone`, `clone-raw`, `clone-cp`, `clone-worktree`, `worktree`, `worktree-hydrate` (macOS); `overlay`, `btrfs`, `reflink`, `worktree`, `worktree-hydrate` (Linux) |
| `scenarios`             | The S01–S25 and M01 catalog                                                                                                                                                       |
| `codexdrv`, `claudedrv` | Real harness drivers (`codex app-server`; Claude Agent SDK via `driver.mjs`)                                                                                                      |
| `cmd/spike`             | `fixture`, `run`, `e1`, `snapcost`, `concurrency`, `report`, `scan`, `exec-steps`, `clone`, `bwrap-retry`                                                                         |
| `scripts`               | Matrix runners for both hosts, the toolchain experiment, summaries, `ship.sh` (64 KiB-chunked copy to a remote machine)                                                           |
| `daemon/phase-d.patch`  | The env-gated daemon integration used for the Phase D cards (not applied)                                                                                                         |
| `results`               | Compact summaries of every run                                                                                                                                                    |

## Running

```sh
cd tools/spikes/workspaces
mise exec -- go build -o spike ./cmd/spike
./spike fixture -dir /Volumes/External/dieter-spike/tree-dev/small -profile small \
  -assets /Volumes/External/dieter-spike/tree-dev/assets
scripts/mac-matrix.sh script script 1 clone worktree         # label driver repeat providers…
scripts/mac-matrix.sh claude claude 2 clone                  # real Claude turns
scripts/mac-e1.sh                                            # view and snapshot cost
./spike report /Volumes/External/dieter-spike/mac.noindex/script/results.jsonl
```

Run every view and its source on one APFS volume; clones cannot cross
volumes. On Linux, `scripts/linux-matrix.sh` and `scripts/linux-e1.sh` expect
a btrfs home and bubblewrap 0.11 or later.

## Credentials

The harness drivers never touch the operator's homes:

- **Codex:** `codexdrv.PrepareHome` copies `~/.codex/auth.json` into a
  temporary `CODEX_HOME` with the refresh token replaced. It refuses tokens
  that expire within 2 hours.
- **Claude:** `claudedrv` passes only the current access token, as
  `CLAUDE_CODE_OAUTH_TOKEN`, with a fresh `CLAUDE_CONFIG_DIR`.

Delete the temporary homes after a run.
