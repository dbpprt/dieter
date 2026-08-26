---
title: "Security model"
linkTitle: "Security model"
description: "Binary access, cryptographic daemon identity, a bounded relay, and a gateway with nothing sensitive to leak."
group: "Overview"
weight: 3
slug: "security"
---

Dieter's security posture follows one rule: **keep the code and credentials on
the machine that owns them, and give the gateway nothing worth stealing.**

## Binary access, no scopes

Client sessions have binary full access or no access. The configured GitHub
identity—matched on the immutable numeric `DIETER_GITHUB_ALLOWED_USER_ID`, not
the mutable login—is allowed or it is not. There are no scopes to over-grant and
no tokens to scope down.

## Cryptographic daemon identity

A daemon proves possession of its enrolled `Ed25519` key on **every** tunnel
connection. Each relayed request additionally carries a short-lived, method- and
payload-bound assertion, so a captured request cannot be replayed against a
different method or body.

Direct routes use a verified daemon certificate and a five-minute bearer.

{{< callout type="warn" title="Never expose the raw data plane" >}}
The raw local data plane listens on `127.0.0.1:4242` and must stay
loopback-only. An enrolled daemon separately advertises an authenticated TLS
route on an ephemeral loopback port that clients discover through the gateway.
Do not advertise raw port 4242.
{{< /callout >}}

## Revocation

Revoking a daemon closes its relay immediately and invalidates direct access as
its five-minute bearers expire. Unenrolling from the machine itself signs the
request with the enrolled identity, revokes the gateway record, closes the
relay, and removes the local gateway credential—without touching projects,
conversations, schedules, or harness settings.

## What the gateway can and cannot see

| The gateway stores | The gateway never stores |
| --- | --- |
| Account sessions | Projects or working trees |
| Daemon public identities | Transcripts or conversations |
| Presence and route metadata | Files |
| Revocation generations | Harness credentials or API keys |

The public origin intentionally serves only `/healthz`, the minimal GitHub OAuth
routes, the gateway gRPC services, and authenticated `dieter.v1.DieterService`
relay calls. **All other paths, including `/`, return 404.**

## Transport hardening

- TLS 1.3 is enforced on every external hop.
- Relay messages are capped at 16 MiB; queues, buffers, and concurrent streams
  are bounded.
- A canceled relay RPC cancels only that transport RPC and never implicitly
  stops an agent.
- Screens media never flows through the gateway—only bounded WebRTC signaling
  and short-lived ICE configuration do.

## Screens admission

Before applying a WebRTC answer the Mac verifies an Ed25519 binding across the
offer, daemon DTLS fingerprint, session, nonce, lease, control grant, display,
and input epoch. Capture starts only after WebRTC connects and stops when its
renewable lease expires. One explicitly enabled viewer/controller is allowed per
daemon, and every held input is released immediately on disconnect.

## Local secret storage

The macOS app stores its gateway session unencrypted in a user-only file under
`~/Library/Application Support/com.dbpprt.dieter.mac` and never touches Keychain.
Android encrypts the session with a device-bound Android Keystore key. Neither
client retains a GitHub token or a harness credential.
