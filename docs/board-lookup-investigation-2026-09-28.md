# Main board lookup and peer convergence investigation

Investigated on 2026-09-28 against the running 0.4.312 daemons and repository
revision `3f993396`. Live inspection was read-only through the Dieter CLI,
including its daemon-log command. No production records or processes changed.
This document records findings and proposed repair work; no fix was deployed.
The concrete implementation and rollout sequence is in the
[end-to-end recovery plan](board-recovery-plan-2026-09-28.md).

## Findings

Two independent defects explain the incident:

1. CLI board lookup searches the default project's boards instead of the requested
   project's boards. The original Main board is present in the daemon's full
   workspace projection, with its settings and label intact.
2. Peer synchronization on mini-home is blocked by persisted card summaries
   containing the removed `commentCount` field. This prevents full convergence
   even though the daemons report the same release.

There is no evidence that a board tombstone deleted the original or diagnostic
boards. Recreating the original board would be the wrong repair.

## Live evidence

Project: `p_7579c6e179bc`. Original board: `b_709489e95b5a`.

`board show` fails and `board list --project p_7579c6e179bc` is empty through the
local/mini-home and garuda routes. In contrast, `watch sync --count 1` returns:

| Replica | Original board | Additional Main board | Project boardCount | Active project cards |
| --- | --- | --- | --- | --- |
| local / mini-home | `b_709489e95b5a` | `b_0c49b1d5ccc8` | 2 | 42 |
| garuda | `b_709489e95b5a` | `b_33ceb825b8b0` | 2 | 43 |
| mini-office | `b_709489e95b5a` | `b_33ceb825b8b0` | 2 | 43 |

Every active Dieter card in these snapshots references the original board.
Both diagnostic boards survived on their creating replicas; garuda's replacement
also reached mini-office. They were created at 06:51:16Z and 06:52:10Z on
2026-09-28, respectively. Neither has active Dieter cards in these snapshots.

The original board has matching projected values on all three inspected replicas:

- Name `Main`, workflow `review`, lanes Todo, Running, Review, Done.
- Done archive policy `never`, publish mode `manual`, empty base remote.
- Label `label_51b0af86eb70`, name `#YOLO`, color `#7c5cff`.
- Label instructions: “Automatically selectively pull, commit and push to main,
  monitor the GitHub action until the release lands.”
- Last board update: `2026-09-22T20:21:07.966616209Z`.

The original board identity and inspected settings registers have single live
versions; the settings revisions match between mini-home and garuda. The current
domain schema has no board-level `deleted` field. A missing `board.deleted`
record alone would not rule out field tombstones, but the required identity,
name, and workflow records and complete board projection are all present here.

Archived-card queries scoped explicitly to Dieter succeed: mini-home returns
five archived cards and garuda returns three, all referencing the original board.
These are observations during an unconverged state, not a claim that archival
state or placements already agree between replicas. No placements, ordering,
archive flags, labels, or board settings were changed during this investigation.

## Cause 1: CLI requests the wrong projection

`Store.State` in `internal/store/materialized_state.go:16` returns all project
summaries, but only the selected project's boards/cards. With an empty project
reference it resolves using the daemon process's working directory or falls back
to the first project. The observed default is `afa`.

The following CLI paths call `GetState` with an empty request:

- `projectState`, `internal/cli/rpc_projects.go:188`.
- `boardState`, `internal/cli/rpc_projects.go:478`.
- `rpcBoardList`, `internal/cli/rpc_projects.go:566`.

`rpcBoardList` resolves `--project dieter` from the complete project directory,
then filters the already-returned **afa boards** by Dieter's ID. `boardState`
similarly searches afa's boards for the original ID. The error text is generated
by the CLI's `resolveProtoBoard`, before a board mutation reaches the server.

`card create` reuses `projectState` and resolves its board from that same response
(`internal/cli/rpc_cards.go:239`), so it fails before calling `CreateCard`.
`card list --project ...` passes `ProjectId` to `GetState` explicitly
(`internal/cli/rpc_cards.go:346`), so it works.

`board create` only needs the project directory before sending `CreateBoard`;
the daemon durably creates the board. The subsequent CLI lookup uses the wrong
projection and makes the board appear to disappear. The observed board counts
match the actual full-projection board records.

The same empty-request pattern also affects board resolution in schedule
creation/update (`internal/cli/rpc_schedules.go:318`) and scoped board prompt
updates (`internal/cli/rpc_settings.go:256`). Board rename, labels, retention,
Git settings, and hostnames inherit `boardState`'s lookup failure.

## Cause 2: removed summary field blocks replication

mini-home's `peer status` reports its last completed exchange at
`2026-09-25T18:39:56.53907Z`. Its daemon log repeatedly reports:

```text
peer store synchronization pending
peer d_er6e1D_iJlop7H92: unknown shared object field: commentCount
```

For example, this occurred at `2026-09-28T09:03:53.846+02:00`.

Commit `f69f84ead9f6807fd362ddd2a95b8b1ed2b0749f` (2026-09-25, “Remove board
comments and sync unread reply attention”) removed `commentCount` from both
newly generated summaries and `ValidateDomain`'s allowed persisted fields.
It did not make already persisted versions disappear.

Read-only `peer show` calls on mini-office found signed summaries still containing
`commentCount: 0`, including:

```text
c_ce24aa47a603efe8c8c85cf0.summary
c_b4197d3a4b9c1ee9d5b30dab.summary
c_a3e1cfc4c42e48e29860d7ea.summary
c_5aff4122aca3ff173aea703a.summary
```

`ValidateDomain` rejects the field (`internal/peerstore/domain.go:97`).
`MergePeerRecords` validates incoming records before saving the page
(`internal/store/peer.go:177`). On failure, `PeerSync.Exchange` returns before
advancing the pull checkpoint or entering its push loop
(`internal/daemon/peer.go:420`). Retrying encounters the same invalid data.
An obsolete card-summary field can therefore block unrelated board propagation.

This is a persisted-schema validation failure. The observed failure does not
involve board tombstone ordering, a single-board constraint, or board-count
reconciliation deleting records. The inspected board projector does not depend
on card archival state.

## Proposed repair and verification

1. Correct CLI projection selection. Fetch the requested project's state after
   resolving its ID, and request `AllProjects: true` for genuinely global board
   lookups. Audit the schedule and prompt callers too. Keep project selection
   explicit; changing the daemon's working directory is not a repair.
2. Provide a daemon-managed recovery for persisted summary schema evolution.
   Preserve original signed bytes/provenance, causal history, placement and
   archival records. Define how retained old versions are validated and how an
   owner publishes canonical summaries. Do not strip fields from signed peer
   payloads, fabricate clocks, bypass provenance, or discard a failed page while
   advancing its checkpoint. No manual database patch should be needed.
3. Keep `b_709489e95b5a` and all its settings/labels. Separately handle the two
   diagnostic duplicates through a supported, validated cleanup operation after
   checking cards, archived cards, schedules, and references on all replicas.
   The current CLI exposes no board removal operation. A lookup fix alone cannot
   make the “exactly original board” acceptance criterion true now that both
   replacements are known to exist.
4. Add isolated CLI end-to-end regressions with two projects: default `afa`,
   target `dieter`. Verify board list/show, labels/settings, Todo creation on an
   existing board, creation of a second board followed by lookup, and accurate
   counts. Exercise local, direct TLS, and relay routes, plus names and exact IDs.
5. Add persisted-peer regressions containing signed pre-removal summaries,
   including archived cards and forwarded records. Verify restart, concurrent
   exchanges, retained old versions, both replication directions, and recovery
   without changing card placement or archive state. Retain separate tests for
   truly missing parents and stale field tombstones; those are not the observed
   cause of the original board's lookup failure.
6. After release and operational rollout, verify all enrolled replicas, compare
   placement/order/archive records, and create a Todo draft on the original board
   to verify cross-machine visibility. This investigation did not create a live
   test card, deploy software, or claim that acceptance criteria already pass.

Evidence came from live API reads and source/history inspection. No new automated
regression tests or production implementation changes are included in this report.
