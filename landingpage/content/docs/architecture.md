---
title: "Architecture"
linkTitle: "Architecture"
description: "A daemon that owns the code, a gateway that only relays, and native clients that route each action to the machine that owns it."
group: "Overview"
weight: 2
slug: "architecture"
---

The client tries direct TLS, then falls back to the gateway. Both paths expose
the same `dieter.v1.DieterService` API, so the UI does not care which one won.

## The data flow

```text
   ┌───────────────────────────┐
   │   macOS  +  Android        │   all projects, one list
   └─────────────┬─────────────┘
         direct TLS │ or relay
   ┌─────────────┴─────────────┐
   │   board.dbpprt.com         │   auth + bounded relay
   │   sessions + routes only   │   (no project code)
   └─────────────┬─────────────┘
       authenticated tunnel
   ┌─────────────┴─────────────┐
   │   dieter daemon            │   work Mac · home Linux
   │   Git + DIETER_HOME        │   Codex · Claude Code · Pi
   └───────────────────────────┘
```

Gateway access is binary: the configured GitHub identity is allowed or it is
not. There are no scopes. The gateway stores sessions, daemon identities,
presence, and route metadata. **It never stores projects, transcripts, files, or
harness credentials.** Each daemon proves its Ed25519 key on every tunnel connection,
and each relayed request carries a short-lived, method- and payload-bound
assertion.

## Direct routes and the relay

Direct routes use a verified daemon certificate and a five-minute bearer.
Revoking a daemon closes its relay immediately and invalidates direct access as
those bearers expire. Relay messages are capped at 16 MiB, buffers and streams
are bounded, and canceling an RPC does not accidentally stop the agent.

{{< callout type="note" title="One API, two transports" >}}
Because direct TLS and the relay expose the identical `dieter.v1.DieterService`,
the clients treat them interchangeably, preferring a reachable direct route and
otherwise using the relay. Nothing in the UI branches on which won.
{{< /callout >}}

## Terminals

Terminal PTYs follow the same transport rule but have a daemon-owned lifecycle:
canceling an output stream or closing the Mac app removes only that observer.
The shell continues until it exits, is explicitly closed, or the daemon shuts
down. Output carries monotonically increasing sequence numbers and a bounded
replay baseline, so clients can resume after a disconnect without making the
gateway store terminal state. Typing and resize calls use the relay's priority
unary path independently of the long-lived output stream.

## Screens

Screens use the gateway only for bounded WebRTC signaling and short-lived ICE
configuration bound to the authenticated operator and target daemon. The daemon
hosts an H.264 peer with Pion; media and bounded remote input travel directly
over ICE/DTLS/SRTP or through a separately configured TURN server, never through
the Dieter gateway.

The Mac verifies an Ed25519 binding between the offer, daemon DTLS fingerprint,
session, nonce, lease, control grant, display, and input epoch before applying
the answer. Pointer motion uses an unordered no-retransmit DataChannel while
keys, buttons, scrolling, and release-all use a reliable channel. See
**[Screens](/docs/screens/)** for the full lifecycle.

## Persistence

Each daemon owns all domain data under `DIETER_HOME`: projects, boards, cards,
transcripts, queues, schedules, labels, runtime sessions, and worker recovery
records. It uses atomic writes and a cross-process mutation lock. Graceful
daemon shutdown parks active harness turns with provider continuation state;
startup resumes them without replaying the user prompt. An unverifiable orphaned
worker is interrupted instead of risking duplicate tool effects.

The gateway owns a separate SQLite database plus its private signing and
daemon-CA keys. It stores account sessions, pending OAuth and enrollment
records, daemon public identities, revocation generations, presence, and route
metadata. See **[Configuration](/docs/configuration/)** for the storage layout.
