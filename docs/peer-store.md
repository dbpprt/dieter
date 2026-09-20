# Shared projects and the account peer store

Dieter uses one application contract, generated from `api/contract-version` (1),
and storage schema 2. A logical project can contain checkouts on several machines,
including multiple working trees on one machine. Project IDs establish identity;
names, paths, and Git remotes never silently join projects.

## Ownership

Projects, boards, labels, assignments, placement, portable settings, and the item
directory live in the account's replicated store. Every initialized replica can
edit them. There is no project leader or gateway project database. Checkouts,
conversations, files, Git operations, validation commands, credentials, processes,
and schedule definitions/history belong to their execution machine. Directory
summaries let other replicas display them without copying their contents.

A card/chat has one immutable owner and checkout, and at most one active turn.
Separate conversations have no global, harness, or board parallel-session cap.
The schedule capacity queue/skip policy is removed. Durable occurrence and dispatch
receipts still prevent a turn from being replayed after an uncertain delivery.
Resource bounds for transports, remote processes, storage, and background workers
remain in force.

## Records and conflicts

`internal/peerstore` supplies bounded causal multi-value registers independently of
storage and transport. The project consumer uses typed, granular `project`, `board`,
`label`, `assignment`, `item`, `checkout`, and `schedule` records. Each field has a
stable `ENTITY.FIELD` ID; identities and execution references are immutable.
Concurrent independent fields merge. Concurrent edits to one meaningful field keep
all siblings. Explicit resolution covers the currently observed revision; a stale
revision returns `Aborted`. Execution snapshots effective settings/revisions and
blocks when required settings have unresolved conflicts.

Archive/delete projection is conservative: a concurrent archive remains archived.
Missing dependencies defer projection rather than inventing projects or cards.
Card placement is one atomic board/lane/order tuple. Fractional order keys avoid
renumbering a lane. API moves use stable `after_card_id` / `before_card_id` anchors
and an optional observed placement revision. No anchors appends to the lane.
Filtered moves use the displayed neighbors and leave hidden items' keys intact.

Owner records carry an Ed25519 signature binding the account, record identity,
causal clock, exact value, and enrolled certificate. Receiving enrolled replicas
verify the proof, including forwarded records. Historical edits survive certificate
expiry; transport authentication checks current enrollment/revocation. This remains
Dieter's full-access account trust model, not consensus against a compromised member.

## Durability and replication

Account-isolated SQLite replicas live under `DIETER_HOME/peers`. Shared changes,
operation receipts, and pending local file effects commit together. The central
cross-process writer lock, SQLite FULL synchronization, atomic file replacement,
and recovery before writes protect durable local acknowledgement. Schedule summaries
use an outbox in the authoritative occurrence database. Native projection events
follow local commits and peer joins.

`dieter serve` runs unattended account discovery and bounded synchronization. It
prefers verified direct TLS, then data-only WebRTC (direct or TURN), then bounded
relay. WebRTC carries the same authenticated inner TLS/gRPC API. The gateway stores
only its existing account/machine control plane; no project or conversation content
is stored there. A transport disconnect never stops an agent.

Each direction resumes from a durable epoch/sequence checkpoint. A page is joined
before its checkpoint advances. Lost acknowledgements repeat idempotent joins;
a replaced replica epoch triggers bootstrap. One connection at a time rotates
through at most two online peers per round, with jitter/backoff and deadlines.
Shared writes wake synchronization; periodic anti-entropy repairs missed wakeups.
Gateway outage can prevent discovery/authentication/RTC bootstrap, but initialized
replicas still accept local edits and execute their own conversations.

Bounds: 262,144 records, 128 MiB of encoded records per account, 32 KiB per value,
64 actors per register, 16 concurrent siblings, 64 records and 2 MiB per sync page.
Capacity errors are explicit. The 10,000-item/three-persisted-replica fixture covers
80,025 records, catch-up, restart projection, and equal replica hashes. Run with
`DIETER_PEER_SCALE=1 go test ./internal/store -run TestSharedScaleTenThousand -v`.

Tombstones and causal actor history are retained; there is no TTL deletion or
unsafe automatic compaction. Retiring/re-enrolling a machine does not erase shared
history. Restoring an old backup requires a fresh enrollment/actor before editing;
cloning a live enrollment across machines is unsupported. Replication is eventual,
not a transcript backup or a promise that every other machine has acknowledged an
edit. `peer status` reports the last completed exchange, not a quorum.

## Operations

Create a project once, then attach other checkouts explicitly. Creation and initial
board/checkout registration use a durable operation receipt. Conversation creation
uses owner-scoped client/command receipts. Retrying the same request cannot create
a second conversation. Attach/detach operates on the checkout owner. Consolidation
keeps the destination's settings, preserves all boards and conversation identities,
and records a durable source redirect; repository files do not move.

```sh
dieter project create --help
dieter --machine laptop project attach --name Laptop PROJECT /path/to/repo
dieter project checkouts PROJECT
dieter --machine laptop project detach CHECKOUT
dieter project consolidate SOURCE DESTINATION
dieter card move --lane todo --after LEFT --before RIGHT --revision REV CARD
dieter --machine laptop file read --project PROJECT --checkout CHECKOUT README.md
dieter schedule show SCHEDULE
```

Shared reads/edits use a replica; conversation, schedule-detail, filesystem, Git,
terminal, and execution commands use the owner. Use global `--machine ID|NAME` for
CLI owner targeting. An unavailable owner never silently substitutes another machine.
Forks preserve owner/checkout. Merges require both conversations on the same owner;
no transcript or task transfer is implied by sharing a board.

`peer status`, `peer show --kind KIND --id ENTITY.FIELD`, `peer list`, and
`peer changes` inspect the abstract store. Resolve a field with `peer put --kind
KIND --id ENTITY.FIELD --revision REV --file value.json`. The file is the typed JSON
value, including JSON string quotes when appropriate. Read every sibling first.
Protobuf JSON response bytes use base64. `peer merge --file FILE` accepts a bounded
MergePeerRecordsRequest for recovery; never fabricate clocks to force a winner.
The initial abstract `project-settings`/`board-settings` namespaces remain isolated
from domain projection and cannot override the canonical granular project records.

## Development-store cutover

The daemon rejects unsupported project storage without converting it. Use a fresh
`DIETER_HOME` for this pre-release baseline and preserve existing data separately.
No offline import or migration command is provided. Storage schema 2 identifies
the current disk format independently of application contract 1. Tests use
disposable stores and never stop or replace the operator's daemon. See
[application contract](api-contract.md).
