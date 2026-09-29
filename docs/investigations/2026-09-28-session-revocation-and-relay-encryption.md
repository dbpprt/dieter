**Session revocation and relay encryption investigation — 28 September 2026**

Both claims describe gaps in the current implementation. The lost-phone claim
means remotely revoking one native client session; the encryption claim applies
to the gateway API relay, rather than every transport called a relay.

This assessment covers source at `ef2280e090c07da4663076ebacaa292ebbeb72d6`
and isolated tests. It does not establish which release or configuration is
currently deployed. Application behavior was not changed.

**A lost phone cannot be individually signed out from another device: confirmed.**

The gateway's `POST /auth/native/revoke` endpoint authenticates the supplied
bearer and deletes only the session matching that same bearer. It accepts no
target session ID. Possession of the lost phone's token would allow revoking
that token, but signing in on another device supplies a different token.

Session records contain a token hash, account identity, creation time and expiry.
They have no public session ID or device name. The gateway contract exposes
daemon listing/revocation, but no client-session listing or targeted revocation.
Revoking a daemon removes access to that machine for the account; it does not
select a phone's session.

There is a related gap: the macOS `signOut()` implementation and the iOS sign-out
flow delete local credentials without calling the gateway revocation endpoint.
A copied bearer therefore remains usable until expiry or actual server-side
invalidation. Android's `disconnect()` stops local connectivity while retaining
its credential; its credential setter also only changes local storage. No native
client caller of `/auth/native/revoke` was found.

Native sessions default to 30 days, configurable between one hour and 90 days.
Authentication checks Dieter's own session record, so GitHub sign-out or a
GitHub password change alone is not a Dieter session-revocation mechanism.
Once a session is actually revoked at the gateway, new authenticated requests
are rejected and existing gateway streams close on a five-second check.
Already issued direct/WebRTC RPC bearers can remain valid for their remaining
five-minute lifetime plus ten seconds of clock tolerance.

| Evidence | Source |
| --- | --- |
| Self-revocation endpoint and token matching | `internal/gateway/auth.go:474` |
| Session fields | `internal/gateway/storage.go:25` |
| Gateway operations; no client-session management | `api/proto/dieter/gateway/v1/gateway.proto:16` |
| macOS local credential deletion | `apps/mac/Sources/DieterMac/Model/DieterStore+Connection.swift:638` |
| iOS local credential deletion | `apps/mac/Sources/DieterIOS/Model/IOSStore.swift:200` |
| Android disconnect and credential storage | `apps/android/app/src/main/java/com/dbpprt/dieter/connection/DieterConnectionManager.kt:812`; `apps/android/app/src/main/java/com/dbpprt/dieter/data/DieterRepository.kt:455` |
| Session default and expiry configuration | `internal/gateway/config.go:45`, `:108` |
| Gateway stream revalidation | `internal/gateway/auth.go:164` |
| Direct bearer issuance and expiry enforcement | `internal/gateway/service.go:502`; `internal/daemon/direct.go:97` |

**The gateway API relay is not end-to-end encrypted: confirmed.**

External connections use TLS, terminating at the gateway or its configured
reverse proxy. The gateway relay receives ordinary serialized protobuf request
bytes, hashes them, signs a delegation assertion, and places the same bytes in a
daemon-link frame. Responses likewise pass through the gateway as ordinary
protobuf bytes. There is no inner client-to-daemon encryption on this path.

Consequently, the gateway can read relayed messages, file contents and tool
output. The signed assertions protect daemon authorization and payload integrity
relative to the trusted gateway; they do not hide content from that gateway.
The promise that the gateway does not store project data does not imply that it
cannot access data in transit. Existing security documentation already makes
this distinction, although it could state the lack of end-to-end relay
encryption more directly.

| Transport | Content protection |
| --- | --- |
| Gateway API relay | TLS on external connections; gateway can read RPC payloads |
| Direct daemon TLS | TLS terminates at the daemon |
| WebRTC control API, including TURN | Inner daemon TLS remains intact across the byte transport; TURN forwards ciphertext |

The WebRTC distinction is material: TURN and the gateway API relay are separate
paths. WebRTC can fall back to the gateway API relay. The gateway remains trusted
for authentication and certificate issuance even when transport encryption ends
at the daemon; this is not a design that eliminates trust in the gateway.

| Evidence | Source |
| --- | --- |
| Request bytes, gateway signature and response bytes | `internal/gateway/relay.go:77`, `:98`, `:140` |
| Raw protobuf codec, without encryption | `internal/rpcraw/codec.go:11` |
| Daemon forwards the received bytes to its local API | `internal/daemon/gateway_client.go:693`, `:724`, `:754` |
| External TLS policy | `internal/gateway/server.go:169`; `internal/daemon/gateway_client.go:824` |
| Inner TLS over WebRTC and fallback | `docs/webrtc-control-transport.md:13`, `:27`, `:43` |
| Existing storage/transit distinction | `landingpage/content/docs/security.md:40` |

**Recommended work.** First connect native sign-out to server-side revocation
and add account-owned session IDs, device descriptions, session listing, and
targeted revocation across the API, clients and CLI. Preserve the distinction
between local credential removal and confirmed remote revocation. If immediate
revocation of direct streams is required, add session identity and revocation
propagation to daemon authorization; the current mechanism relies on expiry.

For relay confidentiality, carry client-to-daemon TLS or an authenticated
encrypted application channel through an opaque bounded relay. Define whether
the gateway remains a trusted certificate authority or must also be excluded
from identity trust. An end-to-end confidentiality guarantee must also account
for fallback routes.

**Verification.** Thirteen existing targeted tests passed, including subtests,
across `internal/gateway`, `internal/daemon`, and `internal/controlrtc`, using
`go test` with `-count=1 -v`. They cover actual gateway revocation, account
removal, concurrent session storage, authorization rechecks, a daemon enrollment
and relay round trip, tampered/replayed assertions, direct bearer expiry, and
TLS RPCs over both direct WebRTC and an isolated TURN server. These passing
tests validate existing mechanisms; they do not demonstrate missing native
revocation or end-to-end encryption of the gateway API relay.

`just check-changed --dry-run` selected checks for pre-existing Android Activity
changes. Those unrelated native checks were not run for this investigation.
No production session was revoked and no operator service was restarted.
