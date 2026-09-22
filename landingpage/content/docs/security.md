---
title: "Security model"
linkTitle: "Security model"
description: "Understand the trust boundary before connecting your machines."
group: "Reference"
weight: 41
slug: "security"
---

Dieter runs agents with the permissions of the user running the daemon. There is
no Dieter sandbox. Treat an authenticated client as an operator of those machines.

## Account access

The gateway authorizes immutable numeric GitHub IDs from
`DIETER_GITHUB_ALLOWED_USER_IDS`. Each allowed account is isolated from other
accounts. A client session has full access within its account or no access;
there are no granular read-only scopes.

Machine enrollment requires GitHub sign-in and a separate browser approval of
the machine name and enrollment code. The page also shows the public-key
fingerprint. Merely opening the verification link does not enroll a machine.

## Machine identity and transport

An enrolled daemon proves possession of its Ed25519 key on each tunnel connection.
Relay requests carry short-lived, method- and payload-bound assertions. Direct
routes verify the daemon certificate and a short-lived daemon-targeted bearer.
WebRTC API routes retain this daemon TLS authentication, including through TURN.

The raw daemon API stays on loopback (`127.0.0.1:4242`). Never publish that port.
Enrolled daemons advertise a separate authenticated loopback TLS route; an
additional LAN or tailnet TLS route is optional. Public gateway origins require
HTTPS. Literal loopback HTTP is reserved for isolated local setups.

External TLS uses TLS 1.3. If a reverse proxy terminates TLS, configure that
policy at the proxy too. Relay messages, queues, and concurrent streams are
bounded. Transport cancellation never implicitly stops an agent.

## Storage is different from transit

| Location | Stored data |
| --- | --- |
| Daemon | Checkouts and local execution state; transcripts, files, schedules; shared metadata replicas; local harness credentials in their normal configuration locations |
| Gateway | Account sessions, daemon identities, presence, routes, revocation metadata, and normalized credential-free provider quota snapshots |
| Native client | Session credential, caches, drafts, and pending commands appropriate to that platform |

The gateway **does not store** repositories, transcripts, project files, schedules,
provider credentials, or raw provider responses. Authenticated API payloads can
nevertheless pass through its relay. Do not interpret “not stored” as a claim
that the gateway cannot process relay traffic.

Quota snapshots may include a bounded account display email when returned by the
provider's structured account API. Opaque account keys are account-scoped HMACs,
not raw provider account IDs.

Agent model requests follow your provider's configuration. Cloud model providers
may receive prompts, code, and tool output. Dieter does not make that inference
local or replace the provider's data policy.

## Revocation

Revoking a daemon closes its relay immediately. Direct access ends as its
five-minute credentials expire. Signing out or expiring a gateway session closes
its gateway streams within approximately five seconds; direct streams expire
with their bearer, with ten seconds of clock tolerance.

`dieter daemon unenroll` signs its revocation request, removes the local gateway
credential, and leaves projects and conversations intact. Clients stop recovery
on revocation. Read-subscription retries do not restart agents or processes.

## Native session storage

- **macOS:** a user-only session file under
  `~/Library/Application Support/com.dbpprt.dieter.mac`, with `0700` directory and
  `0600` file permissions. It is not encrypted by the app and does not use Keychain.
- **Android:** session encryption uses a device-bound Android Keystore key.
- **iOS:** device-only Keychain items are separated by gateway origin.

Clients retain Dieter sessions, not GitHub access tokens or provider credentials.
Protect the operating-system account and device that hold those sessions.

## Screens and clipboard

Clients verify the signed screen binding before accepting video or input.
Up to four viewers can connect, with one revocable input controller. Held keys
and buttons are released on focus loss or disconnect. Host capture requires the
relevant OS permissions; there is no separate enable switch.

Clipboard sharing is opt-in and available only to the focused controlling viewer.
Its contents do not enter transcript history or logs. Reconnection never replays
an uncertain paste. See [Screens](/docs/screens/) for platform limits.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/dbpprt/dieter/security/advisories/new)
when available. Do not put credentials or an unpatched exploit into a public
issue. The repository's [security policy](https://github.com/dbpprt/dieter/blob/main/SECURITY.md)
describes the report details and fallback.
