# Multi card responsiveness implementation plan

Keep the daemon responsive while many conversations stream output and background
executions continue. Address the measured storage-writer contention first, then
qualify macOS scheduling and control-lane recovery independently.

The mini-home incident on 25 October 2026 involved daemon 0.6.410, repeated
ten-second writer-admission failures, background scheduling priority, high host
load and little free disk space. The live sample identified repeated replica
lookups during conversation writes. These establish a failure mechanism; the
relative contribution of scheduling and disk pressure still needs measurement.

## Constraints

Preserve the [product invariants](../invariants.md): central cross-process
locking, atomic writes, durable acknowledgements, bounded caches and transports,
and one active turn per conversation. Keep concurrency across conversations;
do not add global, harness or board parallel-session caps.

Use temporary homes, isolated repositories, the fixture gateway and explicit
free loopback ports. Never alter the operator's live service or production data
to qualify a change. Keep the existing journal fsync and crash-recovery contract.
UI chunks are already batched, and checkpoints are already encoded and fsynced
outside the writer lock; preserve both optimizations.

## 1 Measure contention under concurrent load

**Targets:** `internal/store/home/lock.go`, `internal/store/replica/view.go`,
`internal/store/conversations/batch_test.go`,
`internal/api/conversation_performance_test.go`, `internal/testkit/topology`.

- Extend writer diagnostics to include timed-out admission attempts as well as
  successful wait and hold duration. Distinguish storage operations with a small
  fixed set of labels. Aggregate in bounded counters or test observers; avoid
  logging every chunk or including transcript content.
- Measure replica query count and duration for each append and runtime-cache
  update in the fixture. Use test instrumentation rather than adding a public
  diagnostics RPC for this work.
- Add a deterministic mock workload with 1, 8 and 16 concurrent turns, a
  100-card directory, short and tool-heavy histories, 10 chunk batches per
  second per turn, capability updates, and concurrent card mutations. Exercise
  directory and conversation watches plus peer exchange during the run.
- Record writer wait/hold p50, p95, p99 and maximum, timeouts, query counts,
  durable events per second, RPC latency, watch lag, CPU, RSS and gateway
  acknowledgements. Separate fixture setup, warmup and steady state.
- Capture baseline results for the incident revision and current main before
  comparing candidates. Report both offered and completed work so dropped
  events or growing queues cannot appear as an improvement.

**Gate:** reproduce contention or quantify which workload boundary triggers it;
verify final sequence numbers, content, receipts and cleanup. Retain the baseline
before choosing a replica-cache or SQL change. A hardware run that cannot be
performed remains an incomplete qualification.

## 2 Remove redundant runtime cache transactions

**Targets:** `internal/engine/turn_execution.go`,
`internal/store/kanban/cards.go`, `internal/engine/turn_batch_test.go`,
`internal/engine/turn_liveness_test.go`.

`persistChunks` currently appends a batch, then calls `UpdateCardCache` with
provider, model and runtime. Even a no-op update acquires the central writer and
resolves the complete shared card before comparing fields.

- Establish the complete set of owner-runtime writers, including admission,
  cancellation, finish, suspension and recovery.
- Track the last successfully published runtime tuple within the active turn
  and suppress identical publications only where that ownership analysis proves
  they are redundant. Initialize it from a verified admission result, and update
  it only after a successful durable write.
- Preserve every real transition and all external cancellation/recovery effects.
  If another legitimate writer can invalidate this tuple during a turn, use a
  bounded authoritative generation check or combine runtime publication with the
  append transaction instead of relying on a stale turn-local value.
- Keep `UpdateCardCache` authoritative and conditional for its other callers.
  Do not use the initial request or a cached conversation as a general substitute
  for reading current replicated card state.

**Gate:** unchanged batches stop acquiring a second runtime-cache writer
transaction. Tests cover provider/model publication, cancellation races,
finishing, queued turns, recovery and failed writes. All final state and response
receipts match the existing behavior.

## 3 Reduce replica work inside conversation writes

**Targets:** `internal/store/conversations/conversations.go`, `batch.go`,
`internal/store/kanban/cards.go`, `shared.go`,
`internal/store/replica/view.go`, `fields.go`.

- Introduce an internal operation-scoped card projection for appends. Reuse one
  bounded replica view and the fields it already loaded across related reads in
  that operation; avoid rebuilding equivalent item, project, checkout, board
  and label projections.
- Define exactly which owner fields a conversation append needs and which shared
  fields must be current when publishing card effects. Separate loading those
  fields from constructing the full client-facing card where safe.
- Validate the view under the central writer lock. Close it at the end of the
  operation. After a replica mutation, invalidate or replace the affected view;
  never reuse a pinned pre-write snapshot to produce a post-write result.
- Preserve causal baselines when saving derived activity, usage and receipts.
  Concurrent title, placement, label, archive and board-lifecycle changes must
  survive an append. A raw local card file is insufficient because its shared
  fields can lag the replica.
- Apply additional query or cache changes only where step 1 demonstrates cost.
  Keep existing record, byte and snapshot bounds. A cache spanning operations
  needs explicit epoch/sequence invalidation and evidence that the added
  complexity is necessary.

**Gate:** lower query counts and writer hold time at equal offered load, with
cross-process mutation, crash replay, torn journal, receipt and causal-state
tests passing. No acknowledgement precedes journal durability.

## 4 Qualify normal macOS service scheduling

**Targets:** `deploy/homebrew/dieter.rb.erb`,
`fastlane/test/helpers_test.rb`, contributor setup and machine documentation.

- Compare the current `process_type :background` with `:standard` using
  disposable launchd jobs and the same workload and resource conditions. Render
  through `Dieter::Release.homebrew`; inspect the resulting service definition.
- Measure effective daemon and child-process priority, per-core activity, writer
  latency, API responsiveness, CPU and thermal behavior. Background launch type
  alone does not establish where each process executes.
- Adopt `:standard` if it improves responsiveness without unacceptable idle cost
  or foreground interference. Do not promote every spawned build to interactive
  priority or introduce CPU affinity.
- Extend the formula-rendering test to assert the selected policy and retain
  stable executable paths, keepalive and staged-release behavior.
- Document that the updated formula's service definition requires explicit
  activation. A staged daemon binary does not refresh the installed launchd job.

**Gate:** fixture evidence demonstrates the scheduling effect independently of
storage changes. Qualification must not restart or replace the operator's
daemon. If it shows no benefit, leave the policy unchanged and retain the data.

## 5 Make quota failures recover without stranding the control lane

**Targets:** `internal/gateway/quota_manager.go`, `hub.go`,
`internal/link/gateway_client.go`, their tests and topology coverage.

- Reproduce a quota reply arriving after its request expires, a duplicate reply,
  a reply on an obsolete connection and a reply from the wrong daemon/account.
- Validate a pending request's identity and operation before consuming it.
  Define a bounded way to recognize expired or duplicate results from the
  authorized sender without accepting unsolicited snapshots or resets.
- Keep harmless late quota outcomes local to quota collection where safe.
  Retain rejection of malformed, oversized and unauthorized results.
- Independently exercise reconnect after missing or delayed HELLO, challenge and
  acknowledgement frames under injected delay. Ensure bounded backoff, fresh
  handshakes and recovery without restarting the daemon or replaying mutations.

**Gate:** delayed quota work cannot consume another caller's pending request,
and legitimate reconnect restores acknowledgements after contention clears.
Keep mutual TLS, device trust and all relay limits unchanged. Treat this as an
independent reliability fix, not a proven cause of storage contention.

## Validation and acceptance

Use separate changes for measurement, redundant runtime updates, replica reads,
service policy and control recovery. Each change includes its focused tests and
before/after evidence. Run cold builds separately from performance measurement.

Proposed performance targets for a ten-minute isolated 8-turn and 16-turn run on
the reference 16 GiB M4, with at least 20 GiB free disk:

| Measure                             | Target                                                                                  |
| ----------------------------------- | --------------------------------------------------------------------------------------- |
| Writer admission                    | No ten-second admission failures                                                        |
| Writer wait                         | p99 below 500 ms; maximum below 2 seconds                                               |
| Lightweight local and relayed reads | p95 below 1 second; p99 below 2 seconds                                                 |
| Watch delivery                      | p99 below 1 second, measured from durable commit                                        |
| Control and peer sync               | No spurious disconnects or writer-busy failures in the normal run                       |
| Correctness                         | Every accepted event recoverable in order; correct final runtime and receipts           |
| Boundedness                         | No increasing backlog at fixed offered load; queues and caches stay within their limits |

These are qualification targets, not claims about current performance. Establish
exact workload and measurement boundaries in step 1. Run a separate constrained
resource scenario with injected slow writes and quota delays to verify explicit
errors and recovery; do not fill the operator's disk to reproduce pressure.

Start verification with `mise exec -- just check-changed --dry-run`. During
implementation, use focused store, engine, API, gateway and link tests, including
race tests for changed concurrency paths. Run the selected checks once at the
integration boundary, plus CLI topology coverage over local, direct TLS and relay
for affected behavior. Run `just fmt` and the relevant lint checks before handoff.
Run `ruby fastlane/test/helpers_test.rb` for formula changes. Use registered
background processes for long-running checks and collect their results.

This plan needs no new RPC or app screen. If implementation adds public
telemetry, complete schema generation, CLI parity, route tests, shared-core
rules, user documentation and skill updates in that same change. Native UI
changes additionally require the affected device qualification.

## Rollout and operational guidance

Land storage and control changes behind passing evidence, then release through
the existing pipeline. Keep service-policy activation a separately observable
operator step. Verify the live daemon version and effective launchd policy after
an operator-approved activation; do not assume a Homebrew upgrade activated it.

Retain enough disk headroom for builds and inspect registered background
executions alongside active agents when distributing work across machines.
Document this in `site/content/docs/machines.md`; preserve the documented right
of registered executions to outlive a turn. Do not automatically delete caches,
cancel another card's execution or change the disk-admission floor without a
separate resource-policy decision.

Stop progression if correctness or boundedness regresses. Revert the individual
candidate change and repeat its affected checks. Production activation and
rollback remain explicit operator actions through the supported service and
release lifecycle.
