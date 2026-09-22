---
title: "Architecture"
linkTitle: "Architecture"
description: "Shared project metadata, machine-owned execution, and one application contract."
group: "Reference"
weight: 40
slug: "architecture"
---

## Three components

| Component | Owns |
| --- | --- |
| `dieter` daemon and CLI | Local checkouts, conversations, harness workers, files, terminals, processes, and schedules; a replica of shared account metadata |
| `dieter-gateway` | Account sessions, enrolled machine identity, presence, route metadata, and normalized provider quota snapshots |
| Native clients | Presentation, local caches, drafts, and durable pending client commands |

The Go daemon hosts agents on macOS and Linux. SwiftUI clients serve macOS and
iOS; Kotlin/Jetpack Compose serves Android. The CLI uses the same daemon API as
the apps. The public website is independent of the gateway and runs no agents.

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
See the [peer-store reference](https://github.com/dbpprt/dieter/blob/main/docs/peer-store.md).

## One API, three routes

Clients prefer:

1. **Verified direct TLS** to an advertised daemon route.
2. **Data-only WebRTC**, using a direct ICE pair or TURN when supported.
3. **Authenticated gateway relay** if earlier routes cannot connect.

All carry the same `dieter.v1.DieterService` contract. WebRTC API transport is
independent of Screens and requests no capture permissions. It carries an
end-to-end daemon TLS connection through a bounded reliable data channel.
TURN is a relay, even when used as the WebRTC route.

Watches resume from the last delivered sequence or complete sync projection.
Transient recovery does not replay domain mutations, process starts, or stdin.
Canceling a relay RPC cancels that transport operation, not an agent turn.

## Durability and bounds

All daemon metadata lives centrally under `DIETER_HOME`, default `~/.dieter`.
Mutations use atomic writes and a central cross-process lock. Repositories remain
ordinary Git working trees; Dieter metadata is not stored inside them.

Graceful shutdown preserves provider continuation state. Recovery attempts to
resume without replaying the initial prompt; unverifiable orphaned workers are
interrupted rather than risking duplicate effects. Runtime leases allow one
active turn per conversation while permitting independent conversations to run
concurrently.

Queues, messages, relay streams, output retention, and process counts have
resource bounds. A bounded recent transcript can load before complete history;
clients fetch older messages and large tool output as needed.

## Synchronization

Daemons synchronize peer records without a client remaining open. Native clients
keep account-specific caches and durable pending commands. A sync heartbeat
proves reachability, not that workspace data has been applied. Persist a cursor
only with its complete projection; `projectionPending=true` is not a checkpoint.
If a retained projection no longer matches, the client must process an explicit
reset.

## Screens and terminals

Screen signaling uses authenticated RPC. Video and input use a separately
admitted WebRTC session, directly or over TURN. The gateway does not relay screen
media. Four viewers can share a host; one holds the control grant at a time.

Terminal output has a bounded replay cursor. With tmux installed, the shell can
survive a daemon replacement. Remote executions are a separate exact-argv API
and end on daemon shutdown. [Automation](/docs/automation/) explains both.

## Compatibility

`api/contract-version` is the single application contract across gateway, daemon,
CLI, clients, sync, and screen input. Clients reject missing or mismatched
versions; release version and contract version are distinct.

The project is pre-release. Unsupported development stores have no automatic
migration path. See the [contract reference](https://github.com/dbpprt/dieter/blob/main/docs/api-contract.md)
and [API schema](https://github.com/dbpprt/dieter/tree/main/api/proto).
