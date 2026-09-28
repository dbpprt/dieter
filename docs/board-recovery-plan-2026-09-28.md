# End-to-end plan: Main board lookup, replication, and duplicate cleanup

Status: implementation and qualification in progress. The user separately
authorized committing/pushing main, release, and daemon rollout on all devices. Based on the [investigation](board-lookup-investigation-2026-09-28.md).

## Outcome and fixed decisions

Restore reliable access to the existing board `b_709489e95b5a` in project
`p_7579c6e179bc`, resume account replication, and remove the two empty diagnostic
boards from active navigation through a supported reversible operation.

The original board already exists. Do not recreate it, regenerate its identity,
move its cards, rewrite its settings, or reconstruct its label from a template.
Keep its Todo, Running, Review, Done lanes, placements/order keys, archive flags,
and `label_51b0af86eb70` (`#YOLO`) with its exact existing instructions.

Implementation decisions:

- Use the existing scoped/global `GetState` contract correctly for CLI lookup.
  Do not change the meaning of an empty `GetStateRequest` for every client.
- Accept `commentCount` as a strictly validated retired field in persisted
  `item.summary` records. Preserve signed bytes and causal versions. New summaries
  continue to omit it; current APIs and clients do not regain comments.
- Resume normal bounded anti-entropy from existing checkpoints. No database
  migration, clock fabrication, checkpoint reset, mass summary rewrite, or
  forced conflict resolution is needed for the known field-validation failure.
- Add narrowly scoped **retirement of empty boards**, with restore and inspection.
  Retain identity, settings, labels, causal records and auditability. Do not add
  cascading deletion, a single-board constraint, or automatic duplicate detection.
- A successful mutation means durable acceptance on the admitting daemon.
  Replication health and convergence are reported separately; no quorum guarantee
  is implied.

Retained signed storage values must remain verifiable after feature removal.
Recognizing this retired storage field is not a historical API branch, and does
not relax validation of arbitrary unknown fields.

## Delivery order

| Stage | Deliverable | Depends on | Exit condition |
| --- | --- | --- | --- |
| 1 | CLI lookup fix and multi-project regressions | None | Existing and newly created boards resolve on every CLI route |
| 2 | Signed-record validation repair and peer diagnostics | None | Persisted old summaries synchronize without changing their signatures or losing current values |
| 3 | Reversible empty-board retirement and client projection | 1, 2 | Empty duplicates can leave active navigation; any referenced board remains accessible |
| 4 | Integrated qualification, docs, release artifacts | 1–3 | Route, persistence, concurrency and native acceptance matrix passes |
| 5 | Operator rollout, convergence, duplicate cleanup, verification | 4 | One active original board on each participating replica, with preserved state and successful Todo creation |

Keep stages in reviewable commits. Stages 1 and 2 should each be independently
testable; stage 3 is necessary to meet the one-active-board requirement after the
diagnostic boards were created. Production release and publishing remain manual.

## Stage 1 — Correct CLI scope and creation behavior

Primary files: `internal/cli/rpc_projects.go`, `rpc_cards.go`,
`rpc_schedules.go`, `rpc_settings.go`, and CLI daemon/route tests.

1. Separate project-directory resolution from project-content lookup. A helper
   returning `(project, state)` must return boards/cards for that exact project,
   not an unrelated default project's state. Resolve names with existing
   ambiguity checks, then request `GetState{ProjectId: resolvedID}`.
2. Global board lookup/listing explicitly requests `AllProjects: true`.
   `board list --project` uses the scoped state. Exact IDs stay authoritative;
   duplicate names return an ambiguity error rather than choosing a Main board.
3. Audit every `GetStateRequest{}` and every `resolveProtoBoard` caller, including
   card creation, schedule create/update, board prompts, labels, Git settings,
   retention, hostnames, and archived-card listing by board ID. Preserve the
   documented default-project behavior of commands that intentionally use it.
4. Avoid fetching every card in the account for a project-scoped operation.
   Use the project directory for resolution and the scoped projection for content;
   reserve the global projection for commands that actually search globally.
5. In `Store.CreateBoard`, recheck the parent project's active state inside the
   writer lock before committing. Ensure the acknowledged board is locally
   projectable and its fields committed atomically. Do not acknowledge success
   and then perform fallible durability work. A later explicit archive/concurrent
   change is distinct from failure of the creation transaction.
6. Do not change the peer conflict-resolution algorithm to fix this lookup bug.
   Board counts are derived from the same visible-board set as active listings.

Start with a two-project fixture: `afa` is the daemon default and `dieter` owns
the target board. Assert the pre-fix failures, then verify list/show, label
operations, settings, schedule resolution, Todo creation, board creation followed
by lookup, and counts. Include existing same-named Main boards, ID/name inputs,
an archived parent project, and restart after successful creation.

## Stage 2 — Resume replication without rewriting signed history

Primary files: `internal/peerstore/domain.go`, provenance/domain tests,
`internal/store/peer.go`, peer persistence tests, `internal/daemon/peer.go`,
`internal/server/peer.go`, and `internal/cli/peer_e2e_test.go`.

1. Permit optional `commentCount` only inside `item.summary`, with the original
   nonnegative integer constraints. Reject negative, fractional, string, null,
   out-of-range, and unrelated unknown fields. Current summary writers continue
   to emit only the current schema.
2. Validate owner provenance against the exact received payload. Do not remove
   the retired field before signature verification or re-sign foreign records.
   Domain projection ignores the retired field; missing current reply-attention
   fields retain their documented defaults and do not invent read receipts.
3. Keep page application atomic. A genuinely invalid record rejects its page,
   does not advance its checkpoint, and identifies the blocking record. Duplicate
   valid pages remain idempotent; restart resumes from the committed checkpoint.
4. Test already persisted signed summaries, not just values produced by the new
   writer. Include a third-party forwarding replica, an offline original owner,
   archived cards, concurrent siblings, delayed dominated versions, and cold
   restart. A retired field in a valid old version must not block newer board or
   placement records in the same exchange.
5. Add bounded per-peer synchronization diagnostics: last attempt, last successful
   exchange, direction, failure code, record kind/ID/field, and checkpoint
   progress. Store these locally under `DIETER_HOME`, outside replicated domain
   records; update through the central lock/atomic-write mechanisms.
6. Extend `PeerStoreStatus` and `peer status` output/help to expose those diagnostics.
   Bound retained entries to the supported machine-directory limit and keep error
   text sanitized. Never log raw values, credentials, certificates, or signatures.
   One peer's success must not erase another peer's blocker or imply account-wide
   convergence. Surface actionable sync failure in existing native connection
   status without adding unrelated settings screens.

No new scheduler or synchronization goroutine may start when a test constructs
an HTTP handler. Tests drive exchanges explicitly or start disposable daemons.

## Stage 3 — Retire only unused diagnostic boards safely

Known candidates, to be revalidated after synchronization:

```text
b_0c49b1d5ccc8  created on mini-home
b_33ceb825b8b0  created on garuda
```

Never infer candidates from their shared name `Main`. The original board's exact
ID is the retained target throughout the runbook.

### Operation and storage contract

- Add a granular causal board `retired` field; absence means active. Keep it
  separate from Done-card auto-archive policy and card/project archive state.
- Add explicit `grpcAPI` operations `GetBoard` (exact ID, including retired
  records), `ListRetiredBoards` (project-scoped, bounded pagination), and
  `SetBoardRetired`. Keep Connect a thin adapter. Existing active-board lists
  continue to use the corrected scoped/global state contract.
- `SetBoardRetired` takes the exact board ID, desired state, observed lifecycle
  revision, and a caller operation ID. Reuse the transaction/receipt framework
  with domain-separated receipt keys. Replaying identical input on the admitting
  daemon returns the same result; reusing a key with different input is rejected.
- `board retire ID`, `board restore ID`, `board list --retired`, and `board show ID`
  expose this through the supported CLI. Inspection includes lifecycle revision,
  effective state, and bounded blocking-reference information. Mutation help
  explains local durability and eventual replication.
- Once `GetBoard` is available, use it for exact-ID inspection instead of fetching
  the global workspace. Keep project-scoped/global listing only for name discovery
  and ambiguity checks; carry exact IDs into mutations.
- Before retiring, check references under the central writer lock against raw
  local and replicated records, not only the visible card list. Any active or
  archived card, unresolved placement sibling, incomplete item carrying the board
  ID, or nondeleted schedule referencing the board blocks retirement. Paused
  schedules still count. Preserve labels/settings rather than deleting them.
- An already retired board cannot accept a new card, placement move, or schedule
  through normal local admission. Revalidate at commit, not only CLI preflight.
- Restore is an explicit causal write preserving the original board record. A
  stale lifecycle revision fails with a conflict and performs no partial mutation.

### Concurrent and offline references

Local emptiness is not proof of global emptiness. Define retirement as an intent
whose effective visibility is guarded by references:

1. A board is effectively retired only when retirement is explicit, has no
   unresolved lifecycle conflict, and no known surviving references exist.
2. Concurrent retire/restore keeps the board visible and exposes the conflict;
   normal form saves must not silently resolve it.
3. If an offline replica later delivers a card or schedule referencing a retired
   board, retain both records, make the board accessible again, and report that
   retirement is blocked. Do not discard the reference, move its card, or rewrite
   the retirement register automatically.
4. Scan all relevant causal siblings when determining references. A selected
   placement alone cannot prove that a board is unused.

Use a reference index built once per captured peer snapshot so global projection
does not become a boards-times-cards scan. Cap diagnostics, not correctness of
the reference check. Existing peer-store resource bounds still apply.

### Native and watch behavior

Retirement must survive client merging of snapshots from multiple daemons. Merely
omitting a board from one snapshot would allow a stale replica to resurrect it.

- Carry bounded causal board-lifecycle evidence using the existing state-field
  approach, plus explicit retired-board projection/removal evidence in snapshot
  and delta contracts. Do not order lifecycle changes by wall-clock timestamps,
  unrelated replica cursors, or lexical revision strings.
- Update Mac/shared Apple and Android directory merging to retain this evidence
  across reconnects, and give surviving references precedence over hiding their
  parent board. Handle delayed pre-retirement snapshots and subsequent restores.
- A lifecycle conflict or late blocking reference must appear as actionable
  state, rather than an apparently vanished board. Preserve an open board view
  with a clear retired/restorable state and reject new-card admission while
  effectively retired.
- Keep native interfaces accessible and adaptive. The CLI is sufficient for the
  incident's cleanup mutation; a broad board-deletion settings redesign is not
  part of this repair.

Implement a shared fixture for daemon and native lifecycle projection so both
agree on conflict, stale-observation, and late-reference outcomes.

## Stage 4 — Integration, regression matrix, and release preparation

Every new RPC must be explicit on `grpcAPI`, supported through Connect and local,
direct TLS, and relay CLI routes, and included in `rpcCommand` and offline help
tests. Update root/group/leaf help, `README.md`, the dieter-cli skill, peer-store
documentation, and API contracts. Run `just proto` for Go, copied schemas and
checked-in Swift; Android generates from the authoritative schema.

| Regression | Required result |
| --- | --- |
| Default `afa`, target `dieter`, both with Main boards | Exact target resolves; global ambiguous names are rejected |
| Project count already 1; create another board | Commit succeeds, immediate and restarted lookup succeeds, count becomes 2 |
| Original settings, label, all lanes, archived cards | Lookup and sync repairs leave all records/revisions untouched |
| Real missing/incomplete parent with surviving item records | Defer dependent projection explicitly, retain data, recover when exact parent arrives; never invent a board |
| Old signed `commentCount` summaries | Accept known retired field, preserve bytes/proof, current projection ignores it |
| Bad type, unknown field, forged owner proof | Reject with sanitized record-specific error; no partial page/checkpoint advance |
| Stale name/workflow field tombstone | A causally newer restoration survives replay; concurrent siblings remain explicit and data is retained |
| Three replicas with concurrent creates/edits | Same domain records and projections after quiescent exchange, regardless of merge order |
| Retirement with active/archived/pending/schedule reference | Explicit refusal; no card or setting mutation |
| Concurrent retirement and offline card creation | Card survives and parent remains accessible after merge; blocked retirement is visible |
| Delayed retirement versus newer restore | No re-retirement or native disappearance from stale observations |
| Duplicate/lost responses, crash at commit boundaries | Durable receipt and recovery give one mutation without losing records |
| Native reconnect to stale and current daemons | Causal lifecycle evidence prevents stale resurrection or orphaning |
| Route/watch disconnect | RPC/watch ends; agent turns, executions and scheduler occurrences continue |

Use the existing three-store and authenticated peer-route fixtures. Cover local,
verified direct TLS and relay for operations, and existing WebRTC direct/TURN
paths for autonomous peer exchange. Only add tests asserting meaningful outcomes.

Validation sequence:

1. Run focused tests while implementing: peerstore, store, daemon, server and CLI
   packages, including `TestGRPCAPIImplementsEveryDeclaredRPC` and help contracts.
2. Format Go and regenerate checked-in clients after the final schema changes.
3. Run `just check-changed --dry-run`, inspect the affected components, then
   `just check-changed`. Because shared schema/client projection changes are
   involved, complete the selected native unit and related integration checks.
4. Run focused race/concurrency tests for mutation versus sync/retirement. Exercise
   reordered pages and injected commit failures in isolated fixtures.
5. Use temporary `DIETER_HOME` roots, disposable credentials and random loopback
   listeners throughout. Register independent builds/tests as Dieter background
   processes. Never replace or restart an operator daemon to make a test pass.
   Report unavailable native integration separately from passing checks.

Prepare one canonical SemVer release for gateway, daemon/CLI and native clients.
The new lifecycle record/projection makes older software unsafe to participate;
raise the relevant daemon/client compatibility floors only after all matching
signed artifacts are available. Do not hardcode a release number before release
assignment, and do not introduce historical RPC branches.

## Stage 5 — Production runbook

Execute only after code review, qualification, and the separately authorized
operator rollout. Planning or tests must not trigger an update/restart.

1. **Capture the baseline through APIs.** Enumerate every enrolled machine and
   its release, compatibility and online state. Collect bounded peer snapshots
   and project/card/archived-card/schedule views from the relevant replicas.
   Record original-board and label field values/revisions, card IDs, immutable
   owners/checkouts, placement tuples/order keys, archive versions and assignments.
   Keep recovery evidence centrally under `DIETER_HOME` or in the conversation's
   retained tool results, never as project-repository metadata.
2. **Roll out the qualified release.** Follow the existing signed operator update
   workflow without changing enrollment or execution ownership. Publish floors
   at the documented artifact-availability point. Offline/older replicas remain
   explicitly unverified until updated and reconnected; do not claim they passed.
3. **Wait for convergence before cleanup.** Normal sync must advance beyond the
   former failing pages in both directions, without validation errors. Compare
   the relevant domain registers across replicas, including all causal siblings.
   Last-success timestamps alone are insufficient. Use bounded retries with a
   deadline and report the specific peer/blocker if the gate fails.
4. **Check preservation.** The original board and exact `#YOLO` label must match
   baseline. The preexisting replica differences (42/43 active cards and 5/3
   archived cards during investigation) require a causal join of observations,
   not selecting one replica's counts as authoritative. Compare placements and
   archive registers; classify legitimate concurrent user/agent activity by its
   causal versions rather than treating every new revision as corruption.
5. **Verify duplicate emptiness on every participating replica.** Inspect only
   `b_0c49b1d5ccc8` and `b_33ceb825b8b0`. Require no active, archived, pending or
   schedule references and no lifecycle conflicts. If references exist, stop
   cleanup and report them; do not move/delete cards or resolve conflicts to
   manufacture emptiness. Keep offline machines listed as pending verification.
6. **Retire both duplicates by exact ID.** Use the supported lifecycle command,
   current revision and stable operation ID. Read back after uncertain responses
   instead of blindly replaying. Wait for retirement evidence to converge and
   for native active navigation to contain only the original board.
7. **Exercise real Todo creation in both directions.** Create one clearly named,
   deferred Todo draft on the original board on mini-home and one on garuda,
   with explicit checkout and no labels/auto-title/agent start. Verify each exact
   ID and placement on the other replicas. Then archive those exact test drafts
   through the API and verify their archive state converges. Keep their IDs in
   the run record; they are excluded from preexisting-card preservation checks.
8. **Perform final readback.** On every participating replica, `board show
   b_709489e95b5a` succeeds, active board listing returns exactly that ID,
   `project.boardCount` is 1, the original settings/label match, and all
   preexisting cards remain attached with causally correct placement/archive
   state. Retired listing retains the two diagnostic records for restoration.
   Confirm Mac and Android active navigation and Todo creation agree with CLI.
9. **Monitor subsequent exchanges and reconnects.** Require successful exchange
   cycles after the last mutation, not one immediate read. Repeat relevant
   comparisons when previously offline replicas rejoin. Record unresolved causal
   conflicts; do not silently resolve unrelated changes as part of this incident.

## Recovery if a rollout gate fails

- Before cleanup, leave all existing records intact and stop at the failed gate.
  A sync blocker is a reason to diagnose and fix forward, not reset checkpoints.
- If a diagnostic board must become active again, restore its exact ID through
  the lifecycle API. Restoration preserves its settings and does not affect the
  original board or any conversations.
- Do not downgrade participating daemons to the validator that rejects retained
  summaries or cannot understand retirement records. Any release rollback must
  retain both storage decoding and lifecycle safety, respect compatibility floors,
  and use the signed service workflow.
- Never clear the peer store, reenroll to obtain a new actor, erase tombstones,
  remove archived cards, or stop an agent as a synchronization workaround.

The task is complete only when the final readback and preservation gates pass.
Offline replicas are recorded as outstanding until they reconnect; they are not
implicitly counted as converged.
