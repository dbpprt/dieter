---
title: "Architecture"
linkTitle: "Architecture"
description: "Shared project metadata, machine-owned execution, and release compatibility floors."
group: "Reference"
weight: 40
slug: "architecture"
---

## Three components

| Component               | Owns                                                                                                                                     |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `dieter` daemon and CLI | Local checkouts, conversations, harness workers, files, terminals, processes, and schedules; a replica of shared account metadata        |
| `dieter-gateway`        | Account sessions, enrolled machine identity, presence, route metadata, the signed device roster, and normalized provider quota snapshots |
| Native clients          | Presentation, local caches, drafts, and durable pending client commands                                                                  |

The Go daemon hosts agents on macOS and Linux. A SwiftUI client serves macOS;
Android and iOS share one Compose Multiplatform interface inside thin native
shells. Every client runs on the same Kotlin client core. The CLI uses the same
daemon API as the apps. The public website is independent of the gateway and runs no agents.

## Shared identity, local execution

A logical project has one Dieter-generated identity and can reference several
Git checkouts. Each checkout has a canonical path and an immutable owner daemon.
Project, board, label, placement, and portable settings records replicate through
a leaderless account peer store. No machine owns the logical project.

A conversation or schedule retains one execution owner and checkout. Replication
does not move a running agent or copy a Git working tree. Client operations route
to the owner of the selected conversation, checkout, terminal, or process.

Concurrent peer edits are causal siblings that can require explicit resolution.
A write acknowledges local durability, not a quorum or globally linearizable CAS.
Use `dieter peer status` to inspect local peer synchronization.

## One API, three routes

Clients prefer:

1. **Verified direct TLS** to an advertised daemon route.
2. **Data-only WebRTC**, using a direct ICE pair or TURN when supported.
3. **Gateway relay tunnel** if earlier routes cannot connect.

Native clients start a parallel relay connection if WebRTC is still connecting
after one second, use whichever route becomes healthy first, and close the
unused attempt. Application requests are sent once.

All carry the same `dieter.v1` daemon API (one service per domain), inside the
same TLS 1.3 connection between your device and the daemon. Both ends
authenticate with their keys in your account's device roster, so the gateway
and TURN relay only ciphertext; see
[trusted devices](/docs/security/#trusted-devices). A device that is not
trusted yet reaches no machine. WebRTC API transport is independent of Screens
and requests no capture permissions. Its signaling travels through a relay
tunnel, and the data channel then carries the end-to-end TLS connection. TURN
is a relay, even when used as the WebRTC route.

Watches resume from the last delivered sequence or complete sync projection.
Transient recovery does not replay domain mutations, process starts, or stdin.
Canceling an RPC cancels that transport operation, not an agent turn.

The daemon keeps four separate connections to the gateway, one per traffic
class. Every connection proves possession of the enrolled daemon key, and joins
the same process session and enrollment generation. A client opens a relay
tunnel in one class; the gateway connects it to the daemon's own TLS endpoint
and forwards opaque frames that it cannot read. Traffic classes affect
resources, never authorization.

| Traffic class | Concurrent tunnels per daemon |
| ------------- | ----------------------------: |
| Control       |                             4 |
| Replication   |                             8 |
| Command       |                            32 |
| Subscription  |                            32 |

Apps and the CLI open command tunnels; one tunnel carries one TLS connection
and every call on it. Peer sync between daemons uses replication tunnels.

Tunnels carry frames of at most 64 KiB. Each direction may have eight frames in
flight that the other end has not acknowledged, so a slow reader stalls only
its own tunnel. Each daemon connection has a 64 MiB buffer budget, backed by
independent account (128 MiB) and gateway (256 MiB) budgets for that traffic
class. Messages inside a tunnel remain bounded to 16 MiB, and a daemon serves
at most 64 remote calls at once. A writer stalled for ten seconds resets its
connection. Enrollment revocation closes all four connections and their
tunnels. The gateway retains no shared project or conversation data.

`dieter machine route MACHINE` reports channel connectivity, open tunnels,
limits, buffered bytes, rejections, response freshness, and writer stalls.
Heartbeat presence can remain online while one channel is unavailable.

## Durability and bounds

All daemon metadata lives centrally under `DIETER_HOME`, default `~/.dieter`.
Mutations use atomic writes and a central cross-process lock. Repositories remain
ordinary Git working trees; Dieter metadata is not stored inside them.

Graceful shutdown preserves provider continuation state. Recovery attempts to
resume without replaying the initial prompt; unverifiable orphaned workers are
interrupted rather than risking duplicate effects. Runtime leases allow one
active turn per conversation while permitting independent conversations to run
concurrently.

Queues, messages, relay tunnels, output retention, and process counts have
resource bounds. A bounded recent transcript can load before complete history;
clients fetch older messages and large tool output as needed.

## Synchronization

Daemons synchronize peer records without a client remaining open. Native clients
keep account-specific caches and durable pending commands. A sync heartbeat
proves reachability, not that workspace data has been applied. Persist a cursor
only with its complete projection; `projectionPending=true` is not a checkpoint.
If a retained projection no longer matches, the client must process an explicit
reset.

Clients observe every online machine's account changes, including live activity
for active and recently active conversations. Full transcripts are fetched
separately. Up to eight recently opened conversations keep their transcript
watches while you navigate elsewhere; older entries remain in a bounded cache.
Reopening a cached conversation shows its messages immediately and marks it
**Refreshing** until the owner confirms it has caught up with known activity.
A delayed watch falls back to a bounded read. Activity previews never replace
full message content. Offline or unresponsive machines leave cached messages
readable and show a warning in the conversation.

Peer exchanges run independently, with at most four active exchanges and a
40-second deadline per attempt. A failed peer backs off independently from
15 seconds to two minutes; healthy peers retain their normal cadence. Only
account/discovery failures back off the whole discovery loop. Checkpoints still
advance only after durable merges.

Card placement and runtime observations carry independent causal frontiers in
`stateFields`. Native clients join these observations before presenting
snapshots from different machines, so an older replica cannot undo an
acknowledged move or revive a finished turn. `placementRevision` remains the
accepting daemon's compare-and-swap receipt: a join that only a client has seen
must first be observed by a daemon before the card moves again. Board ordering
follows the shared placement key in either display direction; the Inbox's
Recent list is chronological, and finishing a review does not change a card's
activity time.

Retained shared records and replay receipts use paged storage, so history does
not exhaust a lifetime write quota. Tombstones remain to protect against stale
offline replicas. `dieter peer status` keeps historical failures; workspace
warnings hide offline-peer and expired transport failures but keep unresolved
record rejections visible. `catchup` means bounded page progress; the last
completed exchange advances only when both directions finish.

“Board and settings sync between … is delayed” means recent transport failure
between the named replicas. It covers shared project/board metadata, card
placement, labels, navigation, and portable settings. A record rejection remains
visible until resolved; a recovered transport clears its warning. Repository
files and owner transcripts are outside this replication contract.

## Screens and terminals

Screen signaling uses the same end-to-end encrypted connection as every other
call. Video and input use a separately admitted WebRTC session, directly or over
TURN. The gateway cannot read screen signaling and never relays screen media.
Four viewers can share a host; one holds the control grant at a time.

Terminal output has a bounded replay cursor. With tmux installed, the shell can
survive a daemon replacement. Remote executions are a separate exact-argv API
and end on daemon shutdown. [Automation](/docs/automation/) explains both.

## Compatibility

Gateway, daemon/CLI, and native clients report one canonical SemVer release. The
gateway publishes separate minimum client and daemon releases and rejects
software below those floors. Compatible releases may differ. The stable
`dieter.v1` and `dieter.gateway.v1` package names are namespaces, not historical
API implementations.

The project is pre-release. Unsupported development stores have no automatic
migration path. The [API schema](https://github.com/dbpprt/dieter/tree/main/api/proto)
defines the current release contract.
