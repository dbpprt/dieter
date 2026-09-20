# One project, many machines

Implementation record, updated 2026-09-20. See [peer-store.md](peer-store.md)
for the storage, replication, limits, and maintenance contract.

## Product model

A logical project appears once in navigation. It has shared boards and any number
of registered checkouts, including several on the same machine. A checkout has an
immutable owner and a canonical Git working-tree path. Project identity is generated
by Dieter; matching names or Git remotes never silently combine projects.

Create the logical project once, then attach the other machines' checkouts to it.
The add-project forms distinguish new projects from attaching an existing Git
checkout; attachment only asks for the machine, path and checkout name.
Existing logical projects can be consolidated explicitly. Consolidation preserves
boards, cards, chats, schedules, and their identities through a shared redirect; the
destination supplies project defaults. Git files and durable conversations stay
where they are. Concurrent consolidation destinations appear as a shared conflict.

Every card or chat has one immutable execution owner and checkout. The combined
board displays machine badges and supports machine filtering. Shared labels,
placement, archive state, and portable settings can be edited through a reachable
account replica. Conversation contents, starts, cancellation, queued messages,
schedules, files, terminals, Git, and processes route to their owner. An unavailable
owner does not cause another machine to execute its work.

## Implemented boundaries

| Shared account replica | Owner-local data |
| --- | --- |
| Project identity, name, description, prompts, portable defaults | Checkout path and validation commands |
| Boards, workflow and publish defaults | Harness credentials and executable configuration |
| Labels and assignments | Transcripts, attachments, comments, queues and resume state |
| Work-item identity, title, archive state and placement | Runtime leases and workspaces |
| Signed checkout, runtime and schedule summaries | Schedule definitions, occurrence history and dispatch receipts |
| Conflicts, causal context and consolidation redirects | Files, Git state, terminals and exact-argv executions |

No machine is authoritative for a project. The gateway holds authentication,
machine discovery, presence, signaling, route metadata and bounded relay only.
It does not store projects, settings, board records or conversation contents.

The account peer store is an abstract causal register store. Granular typed records
are its first product consumer. Independent edits merge; same-field meaningful
conflicts keep their alternatives for explicit resolution. Required settings
conflicts block new execution. Archive projection is conservative. Native snapshots
and deltas carry explicit shared archive metadata, so a missing dependency is not
confused with an archive performed while the execution owner was offline. Detached
checkout registrations also remain in directory projections as nonselectable
markers; stale cached replicas cannot restore a detached machine choice.

## Replication and durability

- Enrolled daemons synchronize without a native client. Route preference is direct
  authenticated TLS, direct WebRTC, WebRTC through TURN, then bounded gateway relay.
  Every route carries the same application contract and authorization.
- Committed changes wake the worker; bursts are coalesced. Periodic anti-entropy,
  fair peer rotation, deadlines, backoff, and durable per-direction checkpoints
  recover from disconnects. Mismatched machines report an update requirement while
  compatible peers remain eligible for synchronization.
- SQLite transactions commit shared records, operation receipts and local file
  effects together. Atomic writes and the central writer lock protect local state.
  Recovery replays exact pending bytes. Schedule summaries use a durable outbox.
- Ed25519 owner proofs bind account, entity, clock, value and enrollment certificate.
  Forwarded owner records are verified; account changes isolate records and history.
- Ordering uses fractional keys with stable neighbor IDs and optional placement
  revisions. Moves do not renumber a lane. Concurrent placement has a deterministic
  projection; stale revision-checked moves return a conflict.
- Admission records effective settings and revisions. Mid-turn settings edits affect
  later turns. A transport cancellation never implies agent cancellation.

The application contract is **4**, sourced from `api/contract-version` and generated
for Go, Swift and Kotlin. Native clients and peers require that contract. The older
Mac per-project catalog fallback has been removed. Media codec/input negotiation
remains the separate screen-sharing protocol.

## Execution and scheduling

Global, per-harness and per-board parallel-session caps are removed from the model,
API, CLI and native settings. Separate conversations can run concurrently in the
same checkout. There is no distributed execution semaphore. Each conversation still
has at most one active turn, enforced at durable local runtime lease acquisition.
Transport, process and storage resource bounds remain.

Schedules have one execution owner and checkout. Their shared summaries populate
the combined UI; definition, provider catalog, edits, manual runs and history use
the owner. Replication never activates a second scheduler. Deterministic occurrence
identity and ambiguous-dispatch protection remain authoritative. Account changes
cannot reveal another account's local schedule history.

Forks preserve their execution owner and checkout. Merges require the same owner.
Cross-machine transcript transfer and automatic scheduler/conversation takeover
are outside this change; selecting a new machine creates a new conversation.

## Clients and CLI

macOS and Android combine replicas into one project catalog, retain checkouts and
other owners' cached cards, show owner badges, and route execution independently
of the metadata replica. Creation asks for a machine/checkout and loads its harness
catalog. Project settings separate portable defaults from checkout-local validation.
Files, changes and terminals use the explicit selected checkout. Shared conflicts
are inspectable and resolvable. Screenshot capture selects a shared board from the
cached catalog without connecting to a project machine; saving chooses the execution
checkout. Board settings remain directly accessible in compact layouts.
iOS creation and file browsing select a checkout;
conversation selection routes to its owner and keeps the shared directory visible.

The daemon API declares checkout attach/detach/list, project consolidation and peer
inspection/resolution operations. `grpcAPI` is the core and Connect delegates to it.
CLI equivalents support local use and global `--machine ID|NAME`, with help and
transport coverage. See README and the Dieter CLI skill for examples.

## Development-data cutover

Storage schema 2 is a breaking cutover. Normal startup rejects legacy data; there
is no permanent dual domain store. The explicit offline importer provides a dry
run, reference validation, an immutable backup, and resumable activation. It checks
both Markdown and SQLite schedules before mutation, preserves conversation and
occurrence IDs, drains every schedule summary, and refuses a live daemon or worker.
The schema remains unavailable while an import manifest exists. Backup files and
directories are synchronized before the manifest marks the backup ready.

Old capacity-waiting occurrences become interrupted and are never automatically
replayed. Rollback uses the backup and discards post-import edits. No operator data
is imported, deleted or modified by implementation tests.

## Qualification

Use disposable `DIETER_HOME` roots, isolated enrolled gateways/daemons, random
loopback listeners, and test-owned native processes. Required checks are selected
by `just check-changed --dry-run` and run with `just check-changed`.

Coverage includes:

- Three-store independent edits, conflicts, offline-owner edits, consolidation,
  immutable ownership, settings snapshots, account changes and schedule isolation.
- Malformed/forged/forwarded owner records, reordered merges, capacity rejection,
  stale moves, stable neighbors, pending local effects and durable creation retries.
- Autonomous peer exchange and shared-project CLI flows over direct TLS, direct
  WebRTC, forced TURN and relay, plus persisted restart/catch-up.
- Import backup preservation, invalid references, interrupted activation and more
  than one page of schedule summaries.
- Native catalog union, owner routing, checkout selection, conflict and settings
  flows, regenerated bindings and isolated native smoke fixtures.
- An opt-in scale fixture with 10,000 items, 80,025 records and three persisted
  replicas. The measured run converged and rebuilt each replica after restart;
  initial construction took about 10.6 seconds, restart projections about 2 seconds,
  and each database occupied about 31 MiB. Complete fixture time was about 400 seconds.

Verified on 2026-09-20:

- `go test -race ./...` and `go vet ./...` passed, including all four peer
  transport routes and detached-checkout projection/re-attachment.
- Android passed 309 unit tests and seven isolated device tests covering replica
  selection, conversation/terminal creation, project administration, Git changes
  and background transcript synchronization on `Pixel_9_API_37_1`. Device results
  are preserved in `apps/android/build/shared-project-check/project-integration-results-20260920`.
- Swift protobuf input fingerprints passed `just mac proto-check`.
- The macOS unit run passed 703 tests in 34 Swift Testing suites, plus
  five XCTest cases. Both app and test builds reused their canonical caches.
- After integrating upstream through `87b1048c`, the merged clients passed 709
  Mac tests in 34 suites and 310 Android unit tests. The iOS file API conflict
  retained both remote image previews and checkout-aware saves; Android's new
  image-preview path now routes to the conversation owner. Merged iOS sources
  passed syntax parsing; the iOS build limitation below remains.
- macOS packaged-app core, board, machine, sidebar, terminal, capture/island and Git workspace
  journeys passed. Reports and screenshots are retained under `apps/mac/.build/smoke`.
  The conversation suite reported two workspace-pane failures: a requested width
  of 591 points settled at 586, and closing the pane did not restore tail following.
  Existing unrelated conversation-rendering changes remain untouched. External
  accessibility-action and Save-sheet export acceptance checks were skipped by
  the in-process smoke driver and are not claimed as verified.
- Native capture input-state checks passed, but `TestNativeHelperHighRefreshHardware`
  failed to collect 270 frames within its 15-second deadline on both the loaded
  run and one retry with the other task-owned desktop checks idle. The capture
  implementation is unchanged; this remains an unresolved media qualification
  failure, not a passing 120-fps result.
- The Mac screen-viewer run passed undocking, HEVC authenticated transport and
  pixel-alignment checks, but its native end-to-end case failed two cadence
  assertions: 6.02 presented frames/second versus a 45-fps minimum, and insufficient
  presented-frame progress after an intentional UI stall. Overall this screen
  suite failed; opt-in companion, captured-HEVC and recovery-matrix cases were skipped.
- Android's separate screen-viewer journey connected and decoded hardware H.264,
  then failed its relative-pointer X assertion (`0.31770834 → 0.483034` at canvas
  scale `0.5625`). The screen input implementation and test are unchanged. This
  device/media check remains failed; the seven project/workspace journeys above
  passed independently.
- iOS Swift source parsing passed. Build and simulator smoke qualification are
  unavailable on this host: Xcode has no usable iOS 26.5 destination or installed
  simulator device. This is not a successful iOS build or device test.

The task-owned `Pixel_9_API_37_1` emulator saved its snapshot and stopped cleanly.
No Dieter Mac test app remains running. Tests did not restart, replace or import
the operator's daemon.

## Capacity and recovery policy

Limits are explicit: 262,144 records / 128 MiB per account, 32 KiB per value,
64 actors per register, 16 concurrent siblings, and 64 records / 2 MiB per sync page.
Tombstones and causal history are retained. There is no unsafe TTL reclamation or
independent order-key renumbering. Automatic compaction and a retired-replica
rebootstrap protocol require a separate checkpoint design before increasing these
bounds or reclaiming history. Old backups need fresh enrollment/actor identity
before editing; cloning a live enrollment is unsupported.

Replication is eventual. An offline owner uses its last resolved settings and
cannot know an unseen remote policy edit or archive. Gateway availability is still
needed for fresh discovery, credentials and WebRTC bootstrap. Shared replication
does not copy transcripts or synchronize Git working trees.
