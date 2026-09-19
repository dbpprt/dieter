# Multi-machine projects and shared editable boards

Date: 2026-09-19. Status: full implementation proposal; no product changes implemented.
This revision includes shared boards in the required scope and supersedes the earlier
proposal to keep boards separate.

## 1. Product outcome

One project represents the same repository across multiple machines. It appears
once in navigation and can contain multiple boards, each independently editable as
one shared board across all project machines. A board has one set of lanes, labels,
settings, card order, and concurrency limits. Its cards can execute on different
machines. Project chats are combined across machines too.

Example: Dieter / Main shows a card running on MacBook next to a card running on
Linux. Moving either card, editing a label, or changing the board limit updates the
same board for every client. Opening a card connects to its assigned machine.
Files and Git changes remain checkout-specific.

Required scope includes Mac, Android, daemon, CLI, direct TLS, gateway relay,
schedules, capture/Quick Task, offline states, migration, and failure recovery.
No Git syncing, live conversation migration, or automatic machine substitution is
implied by sharing a board.

## 2. Assessment of current code

| Area | Current implementation | Required change |
| --- | --- | --- |
| `internal/model/model.go`, `internal/store/domain.go` | Project owns one canonical path and local ID; board belongs to that project. | Separate logical identity from local registrations and projections. |
| `internal/server/grpc.go`, CreateProject | Registers a project, then creates a local Main board. | Recoverable create/attach workflows with explicit shared-board selection. |
| `internal/store/domain.go`, MoveCard | Writes lane and integer position under a local lock. | Serialize shared ordering at one authority with revision checks. |
| `internal/store/runtime.go`, AcquireRuntimeLeaseFor | Checks global, harness, and board limits using local process leases. | Require durable shared-board admission in addition to local admission. |
| `internal/store/card_merge.go` | Same-store, same-board merge with durable intent and receipt. | Extend intent/receipt protocol across owners. |
| `api/proto/dieter/v1/dieter.proto` | No shared project/board identity or coordinator protocol. | Add explicit models, commands, synchronization, and capability gates. |
| Mac ProjectDestinations and DieterStore navigation/projection | One project ID maps to one endpoint; project selection connects to it. | Separate shared board destination from card/checkout destination. |
| Mac DieterRootView and ChatsView | Sidebar has project-machine badge; ordinary ChatRow hides the badge unless pinned. | Remove single-owner project badge; show machines on all work items. |
| Android DieterConnectionManager | projectHosts maps project ID to one host; directory merges deduplicate by local IDs. | Shared projections plus owner-qualified entity references. |

Current machine authentication, bounded transports, daemon-owned storage, and local
intent/receipt patterns are useful foundations. Daemon-to-daemon coordination is
new work; the existing client-to-daemon relay is not assumed to provide it already.

## 3. Architecture: one durable project coordinator

Each shared project chooses one enrolled daemon as its coordinator. That daemon
owns the logical project catalog and its shared boards. Prefer an always-on machine;
show the choice during setup and allow controlled handoff later. Single-machine
projects use their own daemon, with no network round trip for coordination.

The coordinator serializes shared metadata, membership, ordering, and admission.
Worker daemons own conversations, queues, harness sessions, attachments, workspaces,
processes, files, and Git operations. Clients read the shared board projection from
the coordinator and fetch conversation details from the owner. A board must remain
usable without opening a connection to every worker for every render.

All persistence stays under daemon DIETER_HOME. The gateway stores only existing
account/authentication, machine identity, presence, and route information. It may
route new authenticated peer RPCs; it never stores board data or execution permits.
No Dieter metadata is written into repositories.

This deliberately chooses consistency over accepting conflicting offline shared
writes. Coordinator downtime blocks committed board edits and new board turns;
existing turns continue. Cached boards remain readable. Automatic failover is not
part of this design: safe partition-tolerant failover would require quorum consensus
and a larger deployment/operations model.

## 4. Identity, records, and field ownership

Use daemon-generated IDs and explicit owner references. Retain existing local IDs
and paths for backward references; do not replace every local project ID with one
shared ID. Account/gateway context namespaces client caches and membership.

| Record | Authoritative location | Contents |
| --- | --- | --- |
| SharedProject | Coordinator | Logical ID, name, summary, shared prompt/defaults, membership, coordinator ID/epoch, revision, archive state. |
| ProjectCheckout | Worker | Existing local project ID, shared project ID, canonical path, checkout settings, membership generation, coordinator reference. |
| SharedBoard | Coordinator | ID, project ID, name, workflow, lanes, labels, prompt, policies, host mappings, defaults, limit, revision. |
| BoardBinding | Worker | Shared board ID and local board alias/projection, last applied revision, migration state. |
| BoardCard | Coordinator | Stable shared reference, owner daemon/local conversation ID, checkout, title, lane/order, label IDs, archive/merge state, metadata revision. |
| Conversation | Worker | Existing durable session, initial request, messages, comments, queued turns, attachments, agent selection, workspace and runtime. |
| RuntimeSummary | Worker; cached at coordinator | Runtime/status/usage summaries with owner generation and monotonically increasing sequence. |
| BoardPermit | Coordinator | Board, card, turn/command ID, worker, coordinator epoch, permit state and durable receipts. |
| Operation | Coordinator and affected workers | Idempotency key, payload hash, steps, receipts, conflict/error state, completion. |

Owner-qualified references prevent collisions when central data has been cloned.
Navigation uses logical IDs; conversation/file RPCs use authenticated owner plus
local ID. Audit pins, deep links, tabs, caches, optimistic IDs, and outbox keys.

Each field has one writer. Worker projections of title/lane/labels are caches, not
independent authorities. Worker-generated titles and automatic completion submit
commands to the coordinator. Runtime updates cannot overwrite lane, labels, or
human title edits. A generated title is conditional on its original title revision.

Shared prompt/settings revisions are snapshotted for every admitted turn. Mid-turn
changes affect later turns only. Comments remain worker-owned and never admit work.
Project chats remain owner-bound; shared project configuration is resolved before a
new turn, so stale shared instructions are not silently used during an outage.

## 5. Peer communication and authorization

Add an authenticated daemon-to-daemon transport for metadata delivery, operation
recovery, and permits. It must work without a native client staying open, including
scheduled runs. Prefer verified direct TLS; fall back to bounded encrypted relay.

Do not infer permission from a daemon ID, project ID, or knowledge of a group token.
Define explicit account-approved peer authorization using enrolled Ed25519 identity,
proof of possession, same-account validation, expiring credentials, and revocation.
Enrollment alone is not a substitute for the existing full-access authorization
contract. Retain binary authorized/full-access versus unauthorized semantics; do
not add user scopes. Board membership is domain validation after authentication.
The credential exchange and relay extension require a dedicated security design
review before enabling shared mutations.

Do not copy interactive client bearer tokens or harness credentials between machines.
Bind authenticated peer identity to the claimed worker/coordinator on every RPC.
Reject replayed epochs, wrong-owner receipts, revoked peers, cross-account routes,
and attempts to proxy arbitrary recursive destinations. Route once to authority;
return an explicit redirect/capability error if needed.

Bound peers, in-flight RPCs, fanout, watches, retry queues, frame sizes, attachment
transfers, operation receipts, and retained journal bytes. Use backoff and resumable
cursors. Disconnect cancels transport only, never the agent. Retrying mutations is
allowed only with a persisted operation ID and matching payload hash.

## 6. Shared edits, labels, ordering, and conflicts

Every shared mutation carries an operation ID, expected entity revision, authority
epoch, and explicit field patch. The coordinator validates and commits under its
central lock, atomically with a journal/outbox event. Never hold a filesystem lock
while waiting on a network call. Return the committed revision and operation result.

- Concurrent changes to different entities can both commit. Stale edits to the same
  entity receive the current revision and a conflict response; clients preserve the
  user's draft. Never silently overwrite a concurrent prompt or settings edit.
- Labels have board-wide IDs, name, color, and instructions. Label assignments live
  with BoardCard. Deletion atomically tombstones the label and removes assignments;
  historical turn snapshots preserve the old instructions. Reject stale assignments
  to deleted labels. Recreating the same name creates a different identity.
- Moves specify destination lane and before/after card anchor, plus card/order
  revision. The coordinator assigns order keys and a total sequence. Concurrent
  moves with stale anchors return a conflict for refresh/retry; ties never depend
  on client timestamps. Rebalance keys transactionally without visible reordering.
- A machine filter changes presentation only. Dragging uses visible neighbor IDs
  in the complete lane, preserving hidden cards' relative order. Dropping at the
  filtered end means after the last visible anchor, not an invented global index.
- Moving to Running requests admission; show Waiting until actual execution starts.
  Runtime and workflow lane are separate. Moving an active card to Done does not
  stop its agent or release capacity. An automatic completion updates the lane only
  if the expected phase revision still matches; otherwise preserve the human move.
- Workflow changes that remove lanes require a reviewed mapping of affected cards,
  applied atomically. Board archive blocks new work but does not silently stop turns.
- Retention decisions originate at the coordinator. Workers retain transcripts;
  archiving metadata never implies deleting conversation data. Purging data remains
  a separate explicitly scoped operation.

Offline clients can retain clearly marked pending drafts/edits locally. They are
not committed edits. On reconnect, revalidate revisions; conflicts require resolution.
Never replay a start/send as a fresh operation when an acknowledgement was lost.

## 7. Shared and checkout-specific settings

Shared: project name/summary/prompt, board name/workflow, labels/instructions,
board prompt, retention, browser host mappings, board concurrency, and default Git
policy. Settings edits are committed once at the coordinator, then projected.

Checkout-specific: path, local branch/remote mapping, validation executables and
environment references, available harnesses/models, workspace mode support, and
machine resource limits. Never replicate secrets through shared settings.

Shared Git defaults may name a branch/remote/publish policy, but each checkout must
validate its mapping. Display overrides explicitly. A missing remote, executable,
model, or capability blocks that action with a checkout-specific error; no silent
substitution. Changing defaults cannot rewrite a running turn's workspace policy.

Global and harness parallel limits remain daemon-wide, as today. Label them
"Machine total" and "Machine harness" in UI/help. Board parallel limit is now
project-wide across machines. It is not an account-wide limit on unrelated boards.
Zero keeps the documented unlimited convention, but shared admission still checks
membership, revision, and turn uniqueness.

## 8. Durable board-wide execution admission

A finite board limit must count every machine, including workers currently
unreachable. Use durable permits rather than expiring capacity based on heartbeats.
A disconnected worker may still execute a long turn, so timeout cannot prove release.

Admission sequence for HTTP/CLI/native/schedules/queued follow-ups is the same:

1. Worker persists the queued turn and its stable command ID; validates membership,
   checkout, and harness. Coordinator persists the admission request.
2. Coordinator selects eligible requests fairly (FIFO among ready owners, skipping
   explicitly unavailable ones without blocking everyone) and reserves a slot
   atomically. Reserved plus running plus uncertain permits count against the limit.
3. Worker records the grant durably and atomically acquires its existing runtime
   lease under local machine/harness limits, with the exact permit attached. No
   shared-board runtime may launch through a legacy permit-free path.
4. Worker persists dispatch intent and executes the existing durable conversation
   admission protocol. A lost acknowledgement is reconciled by ID, never a second
   dispatch. The coordinator receives admitted/running status when reachable.
5. On completion, cancellation, or proven non-dispatch, the worker persists a terminal
   receipt/tombstone before releasing local resources and reports it to coordinator.
   Coordinator releases capacity idempotently. Delayed grants for that turn are
   rejected by the worker's tombstone.

If local limits reject a granted turn, release only after recording that this permit
cannot launch, then retry later fairly with a new admission attempt. Avoid holding
network calls inside either local admission lock. Permit IDs and worker incarnation
checks prevent delayed responses from reviving old attempts.

A network partition does not terminate a running turn. Its permit remains occupied.
Workers cannot start another queued turn without another grant. Coordinator restart
loads all reservations as occupied until durable worker receipts settle them; it
must not use local PID cleanup for remote permits. Worker crash recovery reconciles
whether dispatch could have occurred before allowing a release. Uncertain dispatch
is surfaced, never automatically replayed.

Lowering a limit below current occupancy allows existing turns to finish and blocks
new admissions. Changing lanes, archiving, disconnecting, revoking a credential, or
removing a worker from view never frees a permit by itself. Removal drains first.
An operator recovery can release an uncertain permit only after the old worker is
provably stopped/fenced from executing that grant; mere loss of network is insufficient.
Expose occupied, reserved, uncertain, waiting, and blocking machine in diagnostics.

Define one board slot as one root active conversation turn, matching current
parallel-session semantics. Subagents remain part of that turn; do not release its
permit before the harness considers the turn and its owned work terminated.

## 9. Creating cards and choosing machines

New card flow: project → shared board → machine/checkout → harness/model → save or
start. Show destination before submission and remember a valid previous choice.
Do not route based solely on board selection: a board has multiple execution hosts.
New chat uses project → checkout with the same explicit host choice.

Card creation is a durable operation: coordinator reserves BoardCard identity in
Preparing state, worker idempotently creates the conversation and validates/uploads
attachments, then coordinator commits Ready. Failed preparation remains a visible,
retryable operation; it cannot leave an invisible runnable conversation or create
duplicates on retry. Offline target requests show Waiting for machine and do not
claim creation/start succeeded. Set bounded pending-operation/attachment retention.

Before first dispatch, allow Change machine as a staged transfer: freeze the draft,
verify no lease/queued dispatch, prepare destination conversation and attachments,
commit one new owner generation at coordinator, and tombstone the previous draft.
Only the committed owner can receive a permit. Retain stable BoardCard identity and
redirect old draft links; local IDs may differ. Failure resumes from durable steps.

Once a conversation has started, its owner is fixed. Offer an explicit Fork to
machine operation with reviewed copied context and a new conversation/card identity.
It does not transfer the live harness session, working tree changes, or credentials.

Existing card edits route shared fields to coordinator and conversation fields to
owner. Each side reports pending/completed state for multi-step operations. Sending
messages can queue on a reachable owner during coordinator outage, but cannot start
a new shared turn until its admission and current configuration are available.

## 10. Cross-machine merge and board movement

Preserve the existing "merge request into task" behavior across owners in the same
shared board. Coordinator persists a merge operation; source owner freezes an idle
source after checking runtime/queue; target owner durably receives initial request
and attachments once under the merge ID. After target receipt, coordinator marks
source merged/Done. Finalize source projection idempotently. A target that is offline
leaves the operation pending, not falsely completed. Cancellation is allowed only
before delivery; after delivery, reconcile rather than undo a consumed message.
Both histories remain. Use bounded streamed attachment copy, verified digests, and
no dependence on a source-local filesystem URL.

Moving a card between boards in the same shared project preserves its machine and
conversation. Require idle/no pending admission, explicit label mapping, destination
workflow validation, and an atomic coordinator membership/order change. Preserve
history of source labels/settings. Cross-project moves are excluded from this change;
UI explains the project/checkout boundary and offers a fork where appropriate.

## 11. Schedules, Quick Task, and capture

Keep one schedule/occurrence authority on its existing owner daemon. Each schedule
names shared project/board plus a concrete checkout. Every generated task uses a
deterministic occurrence operation ID through shared creation/admission. Owner
outage follows existing missed-run semantics; another daemon never reruns it.
Coordinator outage leaves a durable pending occurrence. Do not replay any occurrence
whose dispatch may already have happened. No scheduler starts when constructing a
test HTTP handler; it still starts only with dieter serve.

Project-wide schedule lists aggregate bounded owner results with freshness status.
Schedule edits target the owner and validate shared board configuration. Handoff of
a coordinator does not implicitly migrate schedule ownership.

Quick Task, browser capture, and global creation select shared project/board, then
checkout. Board hostname mappings precede project mappings as today. Shared match
resolves destination board, not execution machine. Ambiguous/missing host choice
requires selection. Saving capture remains a draft, never an implicit agent start.

## 12. Navigation, badges, and offline UX

- One sidebar project row and one row per shared board. Neither carries a misleading
  single-machine badge. Project settings expose Machines and Coordinator status.
- Shared board renders all cards in one lane order. Every card has its execution
  machine badge, including search/activity and conversation header. Optional machine
  filter does not change board identity or limit scope.
- Project chats combine owners and show badges on every row, including pinned.
  Decouple the existing Mac badge from the pinned drag-handle flag.
- Files/Changes/terminals/workspaces require visible checkout selection. Multiple
  checkouts on one machine show paths as well as machine names.
- Distinguish "Coordinator unavailable: shared edits/new starts waiting" from
  "Linux unavailable: conversation unavailable; last runtime update …".
- Unknown execution state is not Idle. Cached card summaries remain visible with
  freshness indicators; incomplete project counts are labeled.
- Accessibility labels include machine and state; status is never color-only.
  Preserve keyboard navigation, board drag/drop, and adaptive Android layouts.

## 13. Synchronization and recovery

Coordinator publishes bounded shared snapshot/delta streams with authority epoch,
revision, and cursor. Worker publishes owner runtime/conversation summaries with its
own generation and sequence. Persist a cursor only with its complete projection.
Never combine cursors or assume wall-clock timestamps establish event order.

Atomic shared commits include durable outgoing work. Receivers deduplicate and
acknowledge only after applying metadata under their own store lock. Snapshot reset
handles compacted cursors; deletion tombstones prevent resurrection. Deduplication
retention must outlive accepted retry windows. Expired commands return an explicit
reconciliation-required result, never silently become new mutations. Pending
operations and grants retain their receipts until fully settled.

Coordinator keeps latest worker summaries, not transcripts. Worker unavailable
therefore affects detail access and freshness, not board ordering. Local projection
updates from runtime must never overwrite authority metadata. Cache isolation includes
account, logical project, coordinator epoch, and worker ownership generation.

## 14. Coordinator handoff and disaster recovery

Provide an explicit handoff operation, not an automatic election:

1. Validate target membership/version/storage and snapshot replication.
2. Persist a write/admission freeze on old coordinator; drain and reconcile permits
   and multi-step operations. Workers must acknowledge the transition or remain
   excluded and blocked; do not hand off unresolved execution reservations.
3. Copy/verify full catalog, revision history needed for resume, tombstones, receipts,
   and operation state. Persist target Ready without permitting writes.
4. Old coordinator durably commits a signed handoff certificate naming target and
   next epoch, permanently retiring its own write authority for that epoch.
5. Target activates only with the certificate. Peers persist the new epoch; old
   endpoints redirect. Lost acknowledgements resume the same handoff operation.

A resurrected old coordinator cannot become authoritative again. Recovery from an
old backup starts quarantined until authority/epoch is verified against retained
handoff evidence and members. Permanent loss without a complete current snapshot
may require restoring a backup and explicit reconciliation; do not promise zero
metadata loss. The recovery workflow must first fence the old authority and drain/
fence workers with uncertain permits. If that cannot be established, remain read-only.
No button that blindly "force promotes" an offline replica.

## 15. Creation, linking, and migration of existing data

New project: choose first machine/path, shared name, and coordinator (default first
machine); create first shared board and worker binding as one recoverable operation.
Add machine: choose existing project, machine, and path; attach existing registration
or create a checkout. Do not create another Main board implicitly.

Git remotes suggest matches only. Normalize SSH/HTTPS equivalence safely, strip
credentials, preserve host-dependent path case, and handle forks/mirrors/no remotes.
Names or remote equality never silently merge identities.

For existing projects/boards, show a migration preview with member paths, boards,
settings conflicts, labels, cards, schedules, and current limits:

1. Choose destination project/coordinator and explicitly map local boards to shared
   boards. Same-name boards may combine or remain distinct logical boards.
2. Choose workflow/settings and label mappings. Preserve distinct label identities
   when instructions differ. Present a deterministic initial lane order (existing
   per-board relative order, combined in user-chosen source-board order).
3. Choose the new cross-machine board limit explicitly; do not add existing limits
   or take a minimum without review. Machine/harness limits stay unchanged.
4. Stage snapshots/aliases and freeze affected writes/new starts. Drain active turns
   and queued dispatches before cutover, without stopping agents. Pending human
   messages stay durable and wait for migration completion.
5. Commit coordinator catalog, then activate versioned bindings using an idempotent
   migration ID. Until activation is acknowledged, that member cannot admit work.
   Resume schedules only after their mapping is committed. Keep old IDs resolvable.
6. Preserve conversations, pin/deep-link redirects, comments, histories, workspaces,
   occurrence records, attachments, and archive state. Verify counts/checksums.

Before commit, rollback discards staged metadata. After shared writes begin, rollback
is an explicit export/split migration, not restoring old files over newer data.
Removing a checkout drains it and requires resolving retained conversations/schedules;
unlink is not a casual lossless toggle once shared board history exists. Keep old
owner history accessible or explicitly archived. Project archive is authoritative
and blocks admission even while some worker projections lag.

Mixed-version safety: advertise protocol capabilities/API compatibility; reject
unsupported shared mutations. Unlinked legacy projects still work. Old clients
must not use legacy local board APIs to bypass coordination. Updated daemons either
translate supported legacy calls through the authority or return Update required.
Participating old worker daemons must be upgraded before migration. Account changes
and revocation invalidate shared caches/routes without freeing uncertain permits.

## 16. API, CLI, and implementation work packages

Operation names below are proposed contracts, not commands that exist today.
Every operation gets explicit grpcAPI implementation, thin Connect adaptation,
local/direct/relay behavior, offline help, and idempotency/conflict semantics.

| Package | Deliverables and exit criterion |
| --- | --- |
| A. Contracts | Model/field authority ADR, peer authentication design, operation/permit state machines, membership/epoch rules, failure matrix; agreed before mutations ship. |
| B. Coordinator store | Shared project/board/card catalogs, locked atomic journal/outbox, revisions, labels/order/settings, snapshots/deltas, operation recovery. Crash injection proves commits are recoverable. |
| C. Peer transport | Account-approved peer credentials, direct TLS/relay, proof of possession/revocation, bounded retries and summary sync. Works with all native clients closed. |
| D. Shared admission | Durable permits integrated at runtime lease acquisition for every entry point, queue fairness, dispatch receipts, reconciliation and diagnostics. Partition tests prove no capacity oversubscription. |
| E. Work operations | Staged create, draft reassignment, fork, merge, board movement, archive/retention, schedules, attachment transport. Lost-ack tests show one durable effect. |
| F. Migration/recovery | Preview/commit/status APIs, local ID aliases, activation barriers, handoff/restore, mixed-version protections. Existing session/history fixtures survive migration. |
| G. Mac and Android | Shared projections/navigation, checkout selection, unified board/chats, badges, conflicts/pending states, capture and settings. Same fixture renders and routes consistently. |
| H. CLI/docs | Logical IDs plus owner/checkout flags; project create/attach/detach/migration, board operations, operation status, coordinator handoff and permit diagnostics. Global --machine targets entry daemon and routing is explicit. |
| I. Qualification/release | Isolated multi-daemon tests, native UI integration, bounded-load/recovery/security evidence, staged capability rollout and recovery documentation. |

Update proto and regenerate Go/copied schemas/Swift using just proto; Android uses
the authoritative schema. Extend rpcCommand/help contract tests and keep
TestGRPCAPIImplementsEveryDeclaredRPC passing. Update README, dieter-cli SKILL.md,
and AGENTS.md identity/ownership/admission invariants. This plan itself does not
change those invariants or implement proposed commands.

Suggested RPC families: shared project create/inspect/update; member prepare/attach/
drain/detach; shared board CRUD/configuration; card metadata/move/assignment; operation
submit/get/cancel-before-commit; snapshot/watch; worker summary publication; permit
request/grant/settle/reconcile; migration preview/commit/status; coordinator handoff.
Use typed requests/results and operation-specific validation, not an arbitrary
remote-store mutation API. All new APIs need bounded limits and revision contracts.

Sequence A → B/C → D → E/F → G/H → I. UI work can use fixtures once contracts are
stable, but no shared board is released with per-machine-only concurrency checks.
A single-machine project follows the same model via an in-process coordinator;
avoid maintaining two divergent implementations of board semantics.

## 17. Verification and release gates

Run just check-changed --dry-run then just check-changed for implementation changes,
plus affected package/model tests and related native integration fixtures. Use
isolated DIETER_HOME roots, random ports, disposable credentials, and controlled
network faults. Never replace/restart the operator daemon or app. Report unavailable
native coverage instead of claiming success. This documentation-only assessment
has not run implementation tests.

Required evidence:

- Two clients edit one board backed by three machines; labels/settings/order converge,
  stale edits conflict, filtered drag/drop preserves hidden order, and deleted labels
  do not reappear after reconnect.
- Simultaneous starts from CLI, UI, schedule, and queued follow-up never exceed a
  board limit of one/two while also respecting each worker's machine/harness limits.
- Partition after every admission step, lost grant/receipt, worker/coordinator crash,
  delayed old grant, lowered limit, revoked worker, and uncertain dispatch preserve
  capacity and do not replay turns. Transport cancellation never cancels an agent.
- Create, reassignment, merge, migration, and handoff survive crash/retry at every
  durable boundary. Verify one conversation/queue delivery and consistent owner.
- Runtime completion racing manual lane/title edits cannot overwrite human changes.
  Running/Done cards continue occupying slots until actual turn completion.
- Coordinator outage leaves cached boards readable and running turns alive; pending
  edits/new starts are accurately labeled. Worker outage preserves other workers'
  usability and shows unknown/stale state honestly.
- Same-name unrelated repositories stay separate; multiple checkouts, remote URL
  credentials, label conflicts, active schedules, archived data, and pinned links
  survive migration with reviewed settings and no history loss.
- Old clients cannot bypass shared admission; old daemons cannot join unsupported
  groups. Cross-account/wrong-peer/replayed-epoch traffic is rejected on direct and
  relay routes. Handoff cannot leave two active writers, including backup restore.
- Stress bounded subscriptions, journal compaction/reset, operation retention,
  attachment transfer, and reconnect storms; choose documented numerical budgets
  from existing transport limits and benchmark realistic large-board fixtures.
- End-to-end Mac/Android/CLI show one project, one shared board, correct machine
  badges, accessible states, and exact routing over local, direct TLS, and relay.

Release first to disposable fixtures, then an explicitly migrated test project,
then opt-in existing projects. Capability/migration gates prevent partial deployment
from silently changing existing boards. Shared-board acceptance requires the full
coordinator, admission, migration, client, CLI, and recovery path—not visual grouping
alone.

## 18. Key decisions fixed by this proposal

Shared editable boards are required in the first feature release. One daemon is
project coordinator; metadata is consistent and worker execution stays local. Board
limits apply across machines. Offline running turns continue, while new shared
admissions and committed edits require the coordinator. No automatic failover or
live session relocation. All machine selection is explicit and reviewable.

The principal operational cost is coordinator availability. Choose an always-on
machine where possible. Removing that dependency while preserving strict shared
limits would require a separate quorum-replication design, not a badge/UI adjustment.
