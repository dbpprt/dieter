# Application contract

Dieter is pre-release and supports exactly one application contract: **1**.
`api/contract-version` is its source of truth. `just proto` generates the Go,
Swift, Kotlin, and capture-helper constants together with the RPC bindings.
The protobuf packages are `dieter.v1` and `dieter.gateway.v1`; they describe
different services within the same contract, not alternative API versions.

Each daemon stores its local conversations, schedule occurrences, execution
state, and credentials under `DIETER_HOME`. Shared projects, boards, labels,
placements, and portable settings replicate through the leaderless peer store;
no machine owns a project. A checkout references a working tree on its immutable
owner daemon. Conversations and schedules retain one execution owner and checkout.

The daemon's loopback gRPC API is authoritative; Connect is a thin adapter to the
same implementation. Operational CLI commands and native clients use that API.
Authenticated direct TLS, WebRTC, and bounded gateway relay provide routes to it
without changing operation semantics. Store mutations use atomic writes and the
central cross-process lock.

The gateway owns account authentication, enrolled daemon identity, routing,
presence, and normalized provider quota snapshots. It has no project or
conversation store and no public application UI. Daemon browser authentication
and daemon-side OAuth sessions have been removed.

Clients verify the gateway contract and the selected daemon's contract before
using them. Daemon tunnel enrollment verifies it in both directions. Sync and
screen input require the generated numeric contract explicitly; a missing or
different version is an error. Capture-helper control messages use that same
contract. Heartbeat acknowledgement, metadata-first sync,
projection-scoped caches, signed screen session bindings, USB HID keys, and
machine-wide control grants are baseline behavior.

There are no old sync snapshots, screen input versions, cache conversions,
workspace-mode aliases, direct-store operational CLI mode, or store import
commands. Capability discovery remains for actual host/platform differences,
including codecs, capture permissions, clipboard formats, and provider support.

Release versions describe builds and may differ without changing this contract.
Storage schema 2, gateway database schema 1, and internal projection revisions
describe their own persisted formats; they are not additional supported APIs.
Unsupported development databases are rejected without migration. Use a fresh
`DIETER_HOME` or `DIETER_GATEWAY_HOME` for an unsupported store and preserve the
previous directory. Development checks use disposable homes and credentials;
they never reset data or restart the operator's services.

Changes to the baseline update the authoritative schemas, generated bindings,
daemon core, CLI/help, all native clients, and relevant local/direct/relay tests
together. Do not add compatibility branches for historical development builds.
