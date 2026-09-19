# WebRTC for Dieter control connections

Research date: 2026-09-19. Scope: general daemon API calls, chat/sync watches,
terminal and execution streams, and screen-session signaling. This is a
feasibility assessment, not an implemented or benchmarked transport.

**Recommendation: add WebRTC as an optional peer-to-peer API route, keeping
authenticated direct TLS and the gateway relay.** Dieter already has much of the
WebRTC and identity infrastructure. The substantial new work is a bounded RPC
transport across Go, Swift, and Kotlin, plus route recovery and authorization.

The gateway would remain responsible for account authentication, machine
discovery, enrollment, signaling/bootstrap, credential issuance, and fallback.
Once a direct WebRTC connection is established, API payloads can travel between
client and daemon without passing through the gateway. This does not guarantee
that every connection becomes direct: TURN is itself a relay.

## What exists in the repository

| Area | Evidence | Implication |
| --- | --- | --- |
| Direct API route | `internal/daemon/direct.go`; `apps/mac/Sources/DieterClient/ConnectionManager.swift`; Android `DieterRepository.kt` | API traffic is already capable of bypassing the gateway when an advertised TLS address is reachable. WebRTC adds NAT traversal. |
| Bounded relay | `internal/gateway/relay.go`, `hub.go`; `internal/daemon/gateway_client.go` | Existing transport carries method names, protobuf payloads, status, metadata, deadlines, and cancellation. The payload cap is 16 MiB; relay queues have explicit bounds. |
| WebRTC stacks | Pion v4.2.18 in `go.mod`; Mac `RemoteDesktopController.swift`; Android `ScreenController.kt` | All three platforms already use WebRTC and data channels for Screens. |
| ICE configuration | `GatewayService.GetRTCConfiguration`; `internal/gateway/service.go` | Gateway already issues signed, daemon- and operator-bound ICE configuration and short-lived TURN credentials. Actual deployed TURN reachability was not inspected. |
| Peer identity | `internal/remotedesktop/manager.go`, `SessionBindingMessage` | Screen sessions already bind the DTLS fingerprint, offer hash, nonce, expiry, and session details to the enrolled daemon's Ed25519 signature. General RPC needs its own binding and authorization rules. |
| Client transport coupling | Mac `DieterRPC.swift` uses `HTTP2ClientTransport.Posix`; Android repository uses gRPC coroutine stubs | A data channel cannot simply replace the endpoint URL. Client transport integration is a significant part of the work. |

Screen pointer/input already travels over WebRTC. The remaining opportunity is
the general API and its streams, including the RPCs that manage screen sessions.
General API connectivity must work without screen capture or screen permissions.

## Why data channels fit

WebRTC data channels support arbitrary binary messages, full reliability, and
ordered delivery. They use SCTP over DTLS over ICE, providing encrypted transport
and NAT traversal. No audio/video track is required. Use reliable channels for
RPC; the existing unreliable pointer channel is not suitable for commands. [1]

ICE tests candidate paths, including local addresses, STUN-derived addresses,
and TURN relays. STUN helps discover connectivity; it does not relay application
traffic. Restrictive NAT/firewall combinations can require TURN. TURN over TCP
or TLS can help where UDP is blocked, but does not guarantee passage through
every corporate proxy. [2][3]

| Route | Where API bytes travel | Main tradeoff |
| --- | --- | --- |
| Direct TLS | Client ↔ daemon | Already implemented; needs a reachable advertised address. |
| Direct WebRTC | Client ↔ daemon | Adds NAT traversal; incurs ICE/DTLS setup and a new RPC adapter. |
| WebRTC via TURN | Client ↔ TURN ↔ daemon | Endpoint-encrypted payloads; relay bandwidth and operating costs remain. |
| Current gateway relay | Client ↔ gateway ↔ daemon | Existing compatibility and fallback; gateway processes relayed RPC payloads. |

WebRTC may reduce latency and gateway egress on successful direct paths.
Neither savings nor latency improvement can be quantified from code inspection.
For small control messages, setup and maintenance complexity may outweigh the
bandwidth benefit; sustained watches, terminals, and file traffic are stronger
targets. Screen video already bypasses the application gateway.

## Proposed architecture

1. Keep login, discovery, presence, and the daemon's authenticated reverse link.
   Introduce versioned, bounded RPCs for a data-only peer session's offer,
   answer, trickled candidates, status, and closure. Bootstrap these over the
   existing direct TLS or gateway route to avoid a circular dependency.
2. Establish a separate data-only PeerConnection per active client/daemon pair.
   Reuse WebRTC libraries and identity helpers, not the screen session lifetime.
   Closing a viewer must not disconnect chats; connecting a chat must not start
   capture. Separate connections still share the physical network bottleneck.
3. Authenticate the peer and authorize access before dispatching any domain RPC.
   Sign a purpose-separated binding covering the daemon ID/generation, session
   ID, protocol version, client nonce/offer, DTLS fingerprint, and expiry.
   Verify it against the enrolled daemon certificate. Validate the operator's
   short-lived daemon credential, preserving binary full access or no access.
   WebRTC encryption by itself does not establish Dieter account authority. [5]
4. Keep generated protobuf messages and the existing `grpcAPI` core. Carry a
   versioned RPC envelope with request/stream IDs, method, payload fragments,
   deadlines, cancellation, headers/trailers, and terminal status. Reuse relay
   framing concepts, but do not blindly reuse gateway delegation assertions:
   those are signed by the gateway for a particular request and payload.
5. Bound concurrent RPCs, outbound buffers, receive windows, reassembly bytes,
   candidate count, pending sessions, and idle lifetime. Give cancellation and
   small control frames priority. Start with conservative chunks around 16 KiB
   including framing, capped by the negotiated peer maximum. The current
   16 MiB RPC limit is not a safe single data-channel message size. [1][4]
6. Prefer a healthy direct TLS route. While using the relay, try WebRTC in the
   background so ICE does not delay the first useful response. Initially prefer
   direct WebRTC over relay; evaluate TURN versus gateway by observed latency,
   reliability, and operating cost. Report the actual selected route.
7. Move new calls onto the selected route. Existing watches may drain or reopen
   using their established cursors/projection rules. Never blindly replay a
   mutation after an ambiguous disconnect. Closing a transport only cancels
   transport RPCs, not agents, terminals, or remote executions.

Authorization must remain valid throughout long-lived sessions. Define renewal,
bounded expiry, generation changes, logout/revocation propagation, and behavior
when the gateway is unreachable. Existing direct TLS RPCs expire with accepted
credentials, whereas relay watches rely on authenticated gateway session
lifetime. Reusing either path requires preserving its security semantics;
opening a WebRTC connection must not create indefinite authorization.

## Integration choices

**Preferred production direction:** a common protobuf RPC envelope with client
transport adapters. Go can bridge validated calls into the existing core;
Swift's transport abstraction and Kotlin's gRPC channel/call abstraction need
a focused feasibility spike. Generated clients should retain call semantics.
Do not duplicate every domain operation in a second hand-maintained API.

**Alternative spike:** present a reliable data channel as a byte stream and run
HTTP/2 gRPC through it. This can preserve more existing gRPC machinery, but
requires byte-stream adapters on each platform and adds overlapping framing and
flow control. A single ordered stream can also make unrelated calls wait behind
lost data. A local proxy would introduce listener/authentication/lifecycle work.
Choose this only if the cross-platform spike shows a materially simpler design.

Multiple SCTP streams reduce ordered-delivery coupling, but are not a guarantee
of complete isolation: congestion is shared, and large messages can monopolize
an association without message interleaving. Use chunking and fair scheduling;
verify the actual pinned Pion/libwebrtc implementations. [1]

QUIC could be an alternative native transport, but does not by itself supply
peer discovery, NAT traversal, signaling, or a TURN integration. Given Dieter's
existing WebRTC stacks, data channels are the more natural first experiment.

## Bounded prototype and decision criteria

Start with a disposable Go daemon/client fixture, then prove one Swift and one
Kotlin call before broad implementation. Support `Health`, one unary read,
`WatchSync`, and a test mutation that detects duplicate dispatch. Keep the
existing routes available and use isolated credentials and temporary data roots.

Test direct LAN, separate NATs, forced TURN, blocked UDP with TURN/TLS where
supported, IPv6, Wi-Fi/cellular handoff, sleep/wake, and gateway interruption.
Exercise simultaneous watches, a maximum-size RPC, a stalled reader, expiry,
revocation, forged/replayed bindings, cancellation, and disconnect after a
mutation was accepted. Include CLI parity and mixed-version fallback.

Measure cold setup and warm RPC latency, p50/p95 watch delivery, direct versus
TURN success rate, reconnect duration, relay bytes avoided, CPU, memory, and
mobile battery impact. Inspect selected ICE candidate pairs rather than
labeling every WebRTC connection “direct.” Establish acceptance thresholds from
the existing relay baseline before deciding whether to enable by default.

**Assessment:** technically feasible and a good fit for an optional route.
Transport integration and failure semantics make this a substantial feature,
not a small configuration change. A cross-platform prototype is justified;
removing the gateway relay is not justified by the available evidence.

## Primary sources

Retrieved from RFC Editor on the research date. Browser tools were unavailable;
the standards' published plain-text documents were retrieved directly.

1. [RFC 8831 — WebRTC Data Channels](https://www.rfc-editor.org/rfc/rfc8831), especially §§5–6: SCTP/DTLS, reliability, stream behavior, interleaving, and the 16 KB recommendation without interleaving.
2. [RFC 8445 — ICE](https://www.rfc-editor.org/rfc/rfc8445), especially §§2, 5, 9: candidate gathering, connectivity checks, and restarts.
3. [RFC 8656 — TURN](https://www.rfc-editor.org/rfc/rfc8656): relay operation and client/server transport alternatives.
4. [RFC 8841 — SDP for SCTP](https://www.rfc-editor.org/rfc/rfc8841), §6: negotiated maximum message sizes.
5. [RFC 8827 — WebRTC Security Architecture](https://www.rfc-editor.org/rfc/rfc8827), §§4 and 6: signaling, fingerprints, and peer authentication.

No production network probes, implementation changes, or performance benchmarks
were performed for this assessment.
