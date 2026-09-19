# WebRTC control transport v1

The daemon, CLI, Android, macOS, and iOS use the existing authenticated TLS/gRPC
protocol over an optional reliable WebRTC byte transport. Direct TLS remains
preferred; capability-negotiated WebRTC precedes gateway relay fallback. There
is no change to domain RPCs or mutation replay semantics.

Gateway `ResolveDaemonRoute.control_webrtc` is true only when the authenticated,
currently connected daemon advertises `control_webrtc_v1`. Gateway identity,
presence, enrollment, credential issuance, and signaling remain in place. An
older daemon has no capability and is not probed for this transport.

Bootstrap calls `StartControlConnection` on an existing direct/relay route with
signed gateway RTC configuration and a gathered SDP offer, capped at 64 KiB.
The daemon verifies configuration signature, daemon ID/generation, operator,
and expiry. Offer and answer gather for at most three seconds each. Slow ICE
servers can yield an incomplete candidate set; failure falls back to the relay.
Version 1 uses non-trickle SDP; a failed connection is replaced, not ICE-restarted.

The client opens exactly one reliable ordered data channel named
`dieter-control-tls-v1`, without partial reliability. Messages are binary:

| Frame | Encoding | Meaning |
| --- | --- | --- |
| Data | byte `0`, followed by 1–16,383 bytes | Next bytes of the TLS connection. |
| Credit | single byte `1` | One received data frame has been consumed. |

Each direction starts with 16 frame credits and consumes one for each data
frame. Credit is returned only after the consumer accepts that frame. Excess
credit, oversized/empty/unknown messages, unordered channels, queue overflow,
and additional channels close the connection. Native adapters expose one-use
loopback sockets carrying **TLS ciphertext**, not an unauthenticated local API.
The daemon forwards only to its fixed authenticated loopback TLS listener.
Neither side accepts a caller-supplied forwarding destination.

The client validates the enrolled CA and exact daemon certificate identity.
Every RPC still supplies a short-lived daemon bearer; the direct server checks
its signature, audience, generation and lifetime, propagating only the verified
operator subject. DTLS establishes the WebRTC path; inner TLS independently
binds it to Dieter identity. This avoids relying on an unsigned SDP answer for
daemon authentication. Tokens are renewed by existing client credential logic.
Logout/revocation has the same bounded token-expiry semantics as direct TLS.
Android uses explicitly scoped Bouncy Castle TLS/crypto providers for the
Ed25519 daemon certificate; it does not replace Android's global TLS provider.
Foreground RPCs and background machine-directory reads share route selection.

The daemon admits at most 16 control sessions, gives startup 20 seconds, and
caps each transport at one hour. TLS handshake timeout is ten seconds. Each
RPC retains the direct server's 16 MiB message limit and 64-active-RPC cap.
Closing a session or losing a peer cancels RPC transports only. Watches resume
under existing recovery policies; mutations and stdin writes are not replayed.
On native clients a dead peer is replaced through normal connection recovery.
The CLI gRPC dialer can negotiate a fresh peer when its channel reconnects.

`GetControlConnection` reports the actual selected candidate kinds and `direct`,
`turn`, or `unknown`. Either selected candidate being `relay` means TURN. This
label does not claim to identify the TURN client's UDP/TCP/TLS leg. macOS
Machines, iOS, and Android show WebRTC Direct or TURN; CLI status exposes
`webrtc-direct` or `webrtc-turn`. A mode describes the sampled established path.

Tests use disposable identities, local sockets, and an in-process TURN server.
`go test -race ./internal/controlrtc` exercises direct and forced TURN paths,
large TLS/gRPC messages, cancellation, ownership checks and configuration
integrity. CLI route tests cover direct TLS, WebRTC, and relay fallback.

For native integration, `DIETER_TEST_CONTROL_WEBRTC=1` enables the bridge on the
primary daemon of `scripts/isolated-gateway`. It advertises no direct TLS route,
forcing compatible clients through WebRTC. The shared Swift test reads the
fixture's `DIETER_ISOLATED_*` output from `DIETER_CONTROL_FIXTURE`; Android's
`webRTCControlCarriesRPCAndReportsICEPath` test requires the existing isolated
fixture arguments plus `isolatedControlWebRTC=1`. No operator service is changed.

## Validation on 2026-09-19

- Protobuf regeneration and `go vet ./...` passed.
- The control transport race suite passed direct and forced TURN connections,
  multi-megabyte RPCs, watch cancellation, bearer/certificate authentication,
  configuration ownership/integrity, and unsolicited-credit rejection.
- Focused CLI WebRTC/fallback and RPC/help contract tests passed. Full daemon
  and gateway package race suites also passed in the affected-check run.
- Shared Apple integration passed real RPCs, watch cancellation, reconnect,
  directory route selection, and mode reporting. The packaged Mac Machines
  smoke passed its explicit WebRTC assertion; the inspected screenshot shows
  `WebRTC · Direct` in the sidebar and machine popover.
- Android unit tests and the isolated emulator integration passed, including
  foreground and directory reads, cancellation, reconnect, and mode reporting.
  Tests used Pixel_9_API_37_1 / emulator-5554 and disposable credentials.

The full `just check-changed` run stopped on failures outside the new transport:
CLI screen diagnostics and admitted-turn timing, remote-desktop feedback timing,
server updater wording/scheduling, and a service-runtime temporary-path symlink
check. The full Apple run executed 679 tests and reported six assertions in two
conversation-scroll tests; both failures reproduced in isolation. These results
are not a clean repository-wide validation. Native capture input-state checks
passed, but its full regression suite also failed existing media-backpressure,
high-refresh and reference-recovery assertions. The remaining broad UI suites
were not run after these failures. The iOS SDK files are present, but
Xcode has no available iOS simulator runtime/destination and refused the iOS
build; iPhone/iPad execution therefore remains unverified locally.

No gateway or daemon rollout was performed. Updating the gateway, daemon and
clients enables capability negotiation; older combinations retain relay access.
