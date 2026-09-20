# Account peer settings sync after WebRTC implementation

> Historical assessment, superseded by the leaderless implementation in
> [peer-store.md](peer-store.md) and the current
> [multi-machine project plan](multi-machine-projects-plan-2026-09-19.md).
> The single-authority recommendation below is not the target architecture.

Date: 2026-09-20. Source assessment and revised recommendation; no implementation.
Companion to `multi-machine-projects-plan-2026-09-19.md`.

## Conclusion

Yes: implement account-scoped settings replication between daemons, using existing
TLS/gRPC over direct TLS, WebRTC, or relay. Keep project/board data and domain logic
out of the gateway. This is a practical, bounded extension if each shared settings
document has one authoritative writer and peers keep durable replicas.

P2P describes where data travels, not who resolves edits. An authoritative daemon
can synchronize directly with peers without involving gateway board logic. The
previous full plan already put authority on a daemon; the new transport materially
reduces its transport work, not its concurrency or conflict-resolution obligations.

For reasonable effort, retain a project coordinator for shared board mutations and
strict cross-machine admission, while implementing settings replication as a small,
reusable service. Do not build a general multi-writer/offline-first database as a
prerequisite. Full shared boards remain required; settings sync is a work package,
not a replacement for the shared board feature.

## What now exists

Verified from `docs/webrtc-control-transport.md`, `internal/controlrtc/manager.go`,
`internal/controlrtc/stream.go`, `internal/cli/control_connection.go`, and gateway
credential/RTC configuration methods:

- The data-only control transport already carries ordinary TLS/gRPC independently
  of screen sharing. It uses one reliable, ordered channel and credit-based bounds.
- Inner TLS verifies the enrolled daemon certificate. Every RPC still requires
  daemon access credentials; DTLS alone does not authorize account access.
- Existing route preference is direct TLS, then WebRTC, then gateway relay.
  WebRTC may use TURN: peer application endpoints do not guarantee a direct network
  path. Gateway/TURN infrastructure remains useful for connectivity.
- WebRTC sessions have a one-hour lifetime and a 16-session daemon cap. Long-lived
  sync must reconnect/resume and share a bounded connection pool with user traffic.
- The Go dialer is reusable, but route/token orchestration currently lives in CLI
  code. Factor it into a daemon-usable package instead of invoking the CLI from sync.
- RTC configuration and access-token issuance currently use the authenticated client
  principal. Configuration is bound to operator, target daemon/generation, and expiry.
  An enrolled daemon is not already an authorized autonomous client of every peer.

This is source evidence, not a new live direct/TURN test or deployment verification.
The transport documentation reports prior isolated tests and remaining broader test
failures; this assessment does not turn those into a clean repository-wide result.

## Scope of replication

| Data | Policy |
| --- | --- |
| Logical project ID/name, membership references, shared prompt/defaults | Versioned shared documents owned by project coordinator. |
| Board ID/name, workflow, labels/instructions, shared settings/host mappings | Coordinator-owned documents; replicate coherent revisions. |
| Strict board concurrency limit | Replicate configuration; grants and live occupancy still require authoritative admission. |
| Account-level user preferences | Separate explicit allowlist and settings-home daemon; do not merge arbitrary machine settings. |
| Machine global/harness limits, filesystem paths, executable/environment settings | Local to machine/checkout unless a specific portable setting is deliberately defined. |
| Card lanes/order/label assignments | Shared board commands and state, not generic settings blobs. |
| Runtime summaries | Worker-owned, versioned summaries replicated to board projection. |
| Transcripts, harness/provider credentials, queues, files, live process leases | Remain on owner; excluded from settings replication. |

Account scope is an authorization boundary, not an instruction to clone all local
settings. Shared project members subscribe to project settings; optional portable
account preferences have their own explicit scope. Native clients read/write through
a daemon and do not become required always-on replication nodes.

## Minimal replication protocol

Use typed protobuf RPCs over the existing control transport. No extra WebRTC data
channel, custom JSON wire protocol, raw forwarding target, or generic file replication.

A replicated document has account namespace, logical ID, authority daemon/epoch,
schema version, monotonically increasing revision, content hash, typed contents, and
deleted state. Only its authority commits changes. Peers cannot overwrite an equal
or newer version with their local preferences.

1. A client can submit a patch through any connected member. The member forwards to
   authority with expected revision and stable operation ID. Authority atomically
   persists document plus replication journal using the existing cross-process lock.
2. Use list/snapshot and resumable change-watch RPCs. Start with bounded snapshots
   of small settings documents and a revision journal, not a complex per-field delta
   format. Batch independent documents within fixed message/page limits.
3. Receiver validates account, authority/epoch, schema, size, and revision, then
   atomically commits contents plus cursor before acknowledging. Crash recovery
   never leaves an advanced cursor with an old projection.
4. Duplicate events are harmless. Equal revision with a different hash is an
   integrity error; stale authority epochs are rejected. Gaps trigger snapshot
   refresh. Journal compaction triggers an explicit reset, not silent missed edits.
5. Retain deletion markers in snapshots and reject pre-reset incremental uploads;
   a stale offline peer cannot resurrect deleted settings. Authority migration uses
   the full plan's explicit handoff, not election based on who happens to be online.
6. Reconcile on startup, reconnect, membership changes, and bounded periodic checks.
   A watch is a latency optimization, not the only recovery mechanism. Reconnects
   use backoff/jitter and preserve operation IDs; never replay arbitrary mutations.

For coherent board updates, keep labels and their associated settings in one
revisioned board document initially. Cross-record changes that affect card references
remain a coordinator transaction, not separate settings updates.

Use a lazy star per project authority, with pooled connections across projects on
the same daemon. Avoid an always-connected full mesh and flooding every change to
every daemon. Idle replicas can catch up with a snapshot. Reserve connection capacity
for interactive clients; test configurations near the current 16-session cap.

A committed edit means the authority stored it; replicas may still be catching up.
Expose replication freshness. This does not promise zero-loss recovery if the
only authoritative disk dies before replication; that guarantee needs synchronous
replication or a stronger storage design.

## The remaining authentication work

A daemon must discover authorized peers and obtain renewable peer credentials while
no client is open. Add a narrow control-plane credential/bootstrap extension that
uses fresh Ed25519 proof of possession, verifies current same-account enrollment and
revocation, and binds credentials to source identity and target daemon/generation.
Do not reuse a copied desktop bearer token or treat an unsigned daemon ID as proof.

Account approval must explicitly establish autonomous peer access; retain binary
full-access/no-access semantics rather than introducing user permission scopes.
Peer authentication and domain membership validation remain distinct. Update RTC
configuration verification and relay bootstrap consistently with this principal,
without weakening current client authorization. Keep short token lifetimes and
bounded revocation behavior. Sessions need token renewal as well as RTC reconnection.

The gateway may still handle account identity, directory, credential issuance,
signaling, TURN configuration, and bounded relay. No settings contents, revisions,
merge decisions, project membership database, or execution permits go there.
Its existing normalized provider quota snapshot feature is separate and unchanged.

Gateway unavailability can prevent fresh discovery/credentials/RTC bootstrap;
do not advertise completely gateway-independent operation. Previously established
connections remain subject to credential expiry and existing auth behavior.

## Offline edits and the multi-writer alternative

Recommended initial semantics: replicas serve cached settings offline; edits remain
visibly pending until authority commits them. Stale edits return a conflict with the
current value; preserve the user's draft. Never silently choose a winner for a prompt,
label instruction, workflow, or Git publish policy. Starting a turn uses the committed
settings revision attached to admission, not an arbitrary replica's latest cache.

A fully multi-writer alternative is possible, but a different cost/behavior choice:
field-level causal versions, deterministic tie-breaking or conflict objects, delete
semantics, tombstone compaction, schema migration, and reset/rejoin rules. Last-write
wins on wall-clock timestamps is insufficient. Scalar cosmetic preferences might
accept deterministic last-write-wins later; settings with semantic dependencies
need stronger treatment. CRDT convergence alone does not make an edit semantically safe.

Most importantly, exchanging a board limit of two does not stop two disconnected
machines from each starting two turns. Strict limits still require coordination
(or preallocated execution slots with safe transfer, which sacrifices utilization
and adds its own protocol). Keep the full plan's durable permits and never free
capacity merely because a peer disconnects.

## Revised delivery sequence and effort

1. Extract reusable Go authenticated route selection/credential lifecycle from CLI;
   retain direct TLS → WebRTC → relay and current certificate checks. Regression-test
   normal CLI and native control connections.
2. Implement account-approved unattended peer bootstrap/authentication with direct,
   forced TURN, and relay fixtures. Verify revocation and cross-account rejection.
3. Implement the small single-writer settings replication service: typed documents,
   revisions, snapshot/watch, atomic cursor persistence, tombstones, and resumption.
   Gate by capability; preserve local-only behavior for unlinked legacy projects.
4. Apply it to shared project and board configuration. Add minimal client editing,
   stale/pending/conflict status and CLI inspection/update parity.
5. Continue the full shared-board plan: shared card metadata/order, admission permits,
   creation/migration, schedules, merge, and UI. Reuse this transport and settings
   service instead of inventing another peer protocol.

Qualitative effort: settings replication with one writer is moderate, with peer
identity/credential lifecycle the largest new dependency. Fully multi-writer settings
is substantially larger. Full shared editable boards with strict limits remain a
large feature regardless of transport. An elapsed-time estimate before the peer-auth
contract and a vertical slice would imply precision this assessment cannot support.

Useful first vertical slice: edit one shared project setting on Mac, commit it on
authority, observe it on a second daemon/Android, close all clients, reconnect the
second daemon, and verify durable catch-up via direct, forced TURN, and relay. Add
crashes between contents/cursor persistence, one-hour transport expiry, duplicate
commands, stale revisions, revoked peers, and session-cap pressure before expanding.

Run affected Go/proto/CLI/native checks under the repository's changed-check workflow
for implementation. Keep all tests isolated from the operator daemon/app. No running
service changes or implementation tests were needed for this documentation assessment.

## Recommendation

Proceed with peer-to-peer, versioned settings replication and reuse WebRTC control
as-is at the transport layer. Keep gateway changes limited to peer authorization
and connection bootstrap. Retain one daemon authority per project for committed
shared edits and board-wide execution admission. That delivers the requested shared
project/board model with substantially less risk than a new multi-writer database,
without putting project logic or storage on the gateway.
