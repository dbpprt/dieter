# Dieter Remote Desktop Plan

Status: first authenticated, view-only production slice implemented; native host helpers and control remain planned.

Last reviewed: 2026-08-25.

## 1. Outcome

Add a native **Screens** destination immediately below **Terminals** in the
macOS app. It connects to graphical sessions on enrolled machines running the
Dieter daemon on macOS, Windows, or Linux and provides a low-latency,
RustDesk-class viewing and control experience.

The system must be peer-to-peer first. Dieter's gateway remains the account
directory, daemon-presence service, authenticated signaling route, and issuer
of short-lived TURN configuration. Screen video, cursor updates, keyboard,
pointer, and future clipboard/file data do not normally pass through the
gateway.

When ICE cannot create a direct path, encrypted WebRTC traffic may use a
separately deployed TURN service. This is a fallback data plane, not an
extension of the Dieter gateway relay.

```text
Mac app <-> existing direct gRPC or gateway tunnel <-> daemon <-> local IPC <-> desktop helper
    \                                                                     /
     \---------- WebRTC ICE + DTLS/SRTP + SCTP data channels ------------/
                            \-- coturn only when direct ICE fails --/
```

### Implemented first slice

The first product slice selects the Pion challenger for the daemon media host
and an exactly pinned Google WebRTC 151.0.0 XCFramework for the macOS viewer.
It deliberately remains view-only and uses FFmpeg/libvpx as a replaceable
capture boundary while native ScreenCaptureKit/Windows/Wayland helpers are
developed.

The implemented control path includes:

- a native macOS **Screens** destination below **Terminals**, using an
  independent direct-TLS-or-gateway signaling connection and Metal rendering;
- gateway-issued, operator- and daemon-bound RTC configuration with optional
  coturn REST credentials and a five-minute default lifetime;
- coarse screen readiness in daemon presence, with detailed capabilities kept
  on the daemon;
- trickled ICE over bounded unary/server-streaming Dieter RPCs, while video
  remains ICE/DTLS/SRTP peer-to-peer or uses separately configured TURN;
- an Ed25519 session binding over the client offer, daemon DTLS fingerprint,
  nonce, session ID, and lease expiry, verified by the Mac before applying the
  answer;
- explicit per-machine enablement, one active session, view-only enforcement,
  a 30-second renewable lease, bounded detach/reconnect grace, and capture only
  after WebRTC connects; and
- race-tested Pion media plus an isolated full gateway-relay-to-daemon test
  that receives a real synthetic VP8 RTP frame.

The remaining sections describe the target beyond this slice. In particular,
control/data channels, native graphical-session helpers, hardware encoding,
cursor separation, statistics UI, and Android viewing are not implemented yet.

## 2. Product principles

1. **Direct by default.** Gather host, IPv6, server-reflexive, and relay ICE
   candidates. Prefer host/server-reflexive candidate pairs and leave TURN at
   normal relay priority. Never configure `iceTransportPolicy=relay` as the
   default.

2. **Gateway is control, not media.** It carries authentication, machine
   presence, a few kilobytes of SDP/ICE signaling, and short-lived TURN
   credentials. It never carries frames or input events.

3. **The host runs in the graphical user session.** A system daemon cannot
   reliably capture macOS privacy-protected content, Windows interactive
   desktops, or Wayland portals. A short-lived, per-user desktop helper owns
   capture, encoding, WebRTC, cursor collection, and input injection.

4. **Capture only while connected.** The helper starts on demand, shows a local
   sharing indicator, and terminates after the session lease expires. It must
   not keep capturing because a signaling stream disappeared.

5. **Text quality before cinematic motion.** Preserve native resolution and
   reduce frame rate before making text blurry. A screen-content encoder mode,
   separate client-side cursor, and fast input matter more than high-motion
   video tuning.

6. **One operator first.** The first release permits one viewer/controller per
   graphical session. Multi-viewer fanout introduces privacy, encoder, and
   admission questions that are deliberately deferred.

## 3. Fit with the current Dieter architecture

Dieter already has most of the required control plane:

- The Mac app resolves an enrolled daemon, attempts authenticated direct TLS
  candidates first, then falls back to the existing gateway tunnel.

- The gateway stores account sessions, daemon identity, presence, and route
  metadata. It does not store Dieter domain data.

- An enrolled daemon has an Ed25519 identity, a gateway-issued certificate,
  the gateway signing key, and short-lived daemon-bound access tokens.

- The reverse daemon link multiplexes logical RPC streams, so screen signaling
  can reuse it without blocking conversations or terminal streams.

The existing `DirectCandidate` protobuf represents fixed authenticated gRPC
routes such as loopback, LAN, or tailnet addresses. It must not be reused for
WebRTC ICE candidates. ICE candidates are ephemeral, session-specific, and
must be bounded and discarded when the session ends.

## 4. Recommended production architecture

### 4.1 macOS viewer

Use a pinned Google libwebrtc build exposed to Swift as an XCFramework. Wrap:

- `RTCPeerConnectionFactory` for connection lifecycle;
- `RTCMTLVideoView` for Metal-backed rendering;
- WebRTC statistics for route, RTT, loss, bitrate, frames, and quality UI;
- data channels for cursor, input, clipboard, and session messages;
- ICE restart for network changes and sleep/wake recovery.

Add the XCFramework through a SwiftPM binary target. Dieter should build and
publish the artifact from a pinned upstream revision in its own CI, including
checksums, notices, an SBOM, and signing/notarization. A community WebRTC-SDK
fork may accelerate the experiment but should not become an unreviewed binary
supply-chain dependency.

### 4.2 desktop host helper

Bundle a native `dieter-desktop-host` executable for each platform. The
production preference is a small C++ process built with the same pinned
libwebrtc revision as the Mac viewer. It owns:

- OS-native display/window enumeration;
- frame capture and dirty-region metadata;
- hardware/software video encoder selection;
- the host `RTCPeerConnection` and video track;
- cursor shape and position collection;
- data-channel input decoding and platform injection;
- ICE, DTLS/SRTP, congestion control, feedback, and statistics;
- local session indicator and emergency stop action.

The Go daemon owns authorization, admission, session leases, audit summaries,
and helper lifecycle. It starts the helper with an inherited one-time secret
and communicates over a Unix-domain socket or an ACL-protected Windows named
pipe. Pixel buffers never cross the daemon or gateway.

### 4.3 Pion challenger

The phase-one bake-off also evaluates Pion WebRTC in the Go daemon. In that
shape, a smaller native helper captures and encodes frames, then sends encoded
access units and cursor metadata to Pion over local IPC. Pion owns WebRTC and
passes bitrate/keyframe feedback back to the encoder helper.

Pion is attractive because it is active, MIT-licensed, pure Go, and already
provides full ICE, STUN/TURN, trickle ICE, ICE restart, SRTP, RTP/RTCP,
ordered/unordered reliable/lossy data channels, NACK, TWCC, and bandwidth
estimation building blocks. The risk is that Dieter would own more of the
capture/encoder feedback loop and platform hardware integration.

The production engine is selected by measured quality rather than build
convenience alone.

### 4.4 NAT traversal

Deploy coturn independently from the gateway:

- STUN and TURN/UDP on 3478;
- TURN/TCP and TURN/TLS on 443 for restrictive enterprise networks;
- geographically sensible endpoints when usage justifies it;
- short-lived TURN REST credentials, normally five minutes or less;
- allocation, bandwidth, failure, abuse, and relay-ratio metrics;
- per-user and per-daemon quotas.

The gateway exposes an authenticated `GetRTCConfiguration` operation returning
STUN/TURN URLs, expiry, username, credential, daemon ID, and a gateway
signature. A client can use the fields directly. The daemon verifies the
signed envelope before passing it to the helper, so it never receives a
service-wide TURN secret.

TURN sees addresses and encrypted packet flows but cannot decrypt WebRTC media
or data-channel contents. The gateway sees signaling transiently but does not
store it.

## 5. Signaling and API design

The current direct daemon bridge supports unary requests and server-streaming
responses. Use that shape instead of adding a bidirectional streaming
requirement solely for ICE signaling.

### 5.1 Gateway additions

```proto
rpc GetRTCConfiguration(DaemonRef) returns (RTCConfiguration);

message RTCConfiguration {
  repeated RTCIceServer ice_servers = 1;
  string expires_at = 2;
  string daemon_id = 3;
  bytes signed_envelope = 4;
}
```

The gateway may include only coarse, ephemeral screen presence in `Daemon`,
for example platform, helper version, and `remote_desktop_ready`. Detailed
display names and permission state remain daemon data.

### 5.2 Daemon additions

```proto
rpc GetRemoteDesktopCapabilities(google.protobuf.Empty)
    returns (RemoteDesktopCapabilities);
rpc StartRemoteDesktop(StartRemoteDesktopRequest)
    returns (stream RemoteDesktopSignal);
rpc SendRemoteDesktopSignal(RemoteDesktopSignal)
    returns (google.protobuf.Empty);
rpc CloseRemoteDesktop(RemoteDesktopRef)
    returns (google.protobuf.Empty);
```

`GetRemoteDesktopCapabilities` returns:

- operating system and graphical-session state;
- helper installed/running/version state;
- capture and control permission state;
- screen-ready reason when unavailable;
- displays, logical/physical dimensions, scale, rotation, and primary display;
- supported codecs and hardware encoder availability;
- whether control, clipboard, audio, and file transfer are implemented.

`StartRemoteDesktop` includes:

- client SDP offer and initial candidates;
- signed RTC configuration;
- requested display and view-only/control mode;
- requested maximum resolution/frame rate/bitrate;
- client-generated session nonce.

Its stream emits the host SDP answer, trickled host candidates, permission and
capture state, selected candidate-pair state, encoder state, recoverable
errors, and the final close reason.

`SendRemoteDesktopSignal` carries additional client candidates and ICE restart
offers. Enforce strict limits on SDP size, candidate count, candidate length,
and update frequency.

The daemon signs the session ID, nonce, helper DTLS fingerprint, expiry, and
client offer fingerprint with its enrolled Ed25519 key. The Mac app verifies
this against the authenticated daemon identity before accepting media.

## 6. WebRTC media and data protocol

### 6.1 Tracks and channels

- **Video track:** desktop pixels over RTP/SRTP.

- **`session` channel:** reliable and ordered; protocol version, capabilities,
  display geometry changes, pause/resume, control ownership, and errors.

- **`input` channel:** reliable and ordered; key transitions, mouse buttons,
  touch lifecycle, and all-keys-up. Input messages contain monotonic sequence
  and timestamp fields and are idempotently rejected when stale.

- **`pointer` channel:** unordered with zero retransmits; high-rate absolute or
  relative motion and smooth scrolling. Newer coordinates supersede older
  ones.

- **`cursor` channel:** reliable cursor-shape messages plus lossy cursor
  position updates. The viewer renders the cursor locally instead of baking it
  into every frame.

- **`clipboard` channel:** reliable, ordered, explicitly enabled, size bounded,
  text and small-image support after the first release.

- **`file` channel:** future chunked, flow-controlled, resumable transfer. Large
  file traffic should use WebRTC rather than reverting to gateway RPC.

### 6.2 Keyboard model

Send physical USB HID usages and logical text/IME events separately. This
avoids confusing Command/Control/Alt/Windows mappings and preserves shortcuts
across different keyboard layouts. The viewer sends all-keys-up when it loses
focus, releases control, disconnects, sleeps, or observes an unclean session
transition.

The default release-input chord must not be forwarded. Candidate: Control +
Option + Escape, shown persistently until the operator dismisses the hint.

### 6.3 Video policy

Start with:

- VP8 software as the universal interoperability baseline;
- H264 preferred when a verified hardware encoder is available;
- screen-content mode/content hints;
- full native resolution where bandwidth allows;
- frame-rate degradation before spatial-resolution degradation;
- NACK, PLI/FIR, TWCC, rapid keyframe after reconnect, and bounded jitter;
- SDR/sRGB only for the first release;
- 1080p60 and 4K30 product targets.

Evaluate VP9/AV1 after the baseline is stable. H265 is not a first-release
WebRTC interoperability target.

## 7. Platform implementation

### 7.1 macOS host

- ScreenCaptureKit for display/window capture and system-provided content
  selection where appropriate;
- VideoToolbox hardware encoding with software fallback;
- CGEvent-based input injection;
- Accessibility/Input Monitoring and Screen Recording permission checks;
- a signed per-user LaunchAgent/helper identity so privacy grants remain
  stable across upgrades;
- no login window, FileVault unlock, or locked-screen control initially.

The Dieter Mac viewer already targets macOS 15. The host implementation can
therefore use current ScreenCaptureKit APIs without maintaining ReplayKit or
legacy Quartz capture paths.

### 7.2 Windows host

- DXGI Desktop Duplication as the initial whole-display capture path;
- preserve dirty/move rectangles and separate cursor shape/position;
- evaluate Windows Graphics Capture for window capture and modern scenarios;
- Media Foundation/D3D11 hardware encoding with software fallback;
- SendInput for normal interactive applications;
- a per-user helper because Windows services run in session 0;
- a later, explicitly designed elevated broker for UAC secure desktop and
  higher-integrity applications.

The MVP does not promise UAC prompts, the Windows sign-in screen, or control of
applications at a higher integrity level than the helper.

### 7.3 Linux X11 host

- XDamage/XShm capture with cursor metadata;
- VAAPI, NVENC, or software encoding selected through capability probes;
- XTest initially, with uinput only through a narrowly scoped and documented
  permission model;
- enumerate active displays from the logged-in X session.

### 7.4 Linux Wayland host

- XDG RemoteDesktop and ScreenCast portals;
- PipeWire video streams;
- libei input through the portal's EIS connection;
- portal clipboard integration later;
- `persist_mode` and single-use restore tokens where the compositor supports
  them;
- clear UI when user selection or renewed permission is required.

Portable unattended Wayland access, lock-screen access, and compositor-specific
DRM/KMS bypasses are not first-release promises. Headless Linux is a separate
virtual-display product mode, not a side effect of desktop sharing.

## 8. macOS product experience

Add **Screens** below **Terminals** in both expanded and collapsed sidebar
variants. Its badge is the number of online, screen-ready machines rather than
the number of merely online daemons.

### 8.1 Machine browser

Each machine row shows:

- online/offline and last seen;
- platform and helper version;
- `Ready`, `Needs Screen Recording`, `Needs Accessibility`, `No active user`,
  `Locked`, `Portal approval required`, or `Helper unavailable`;
- active remote-session indicator;
- display count and hardware encoder badge when known.

### 8.2 Viewer

The viewer provides:

- display selector and geometry-change handling;
- fit, fill, actual pixels, and full-screen modes;
- view-only/control mode;
- local cursor with correct hotspot and scaling;
- compact auto-hiding toolbar;
- route chip (`LAN`, `Direct`, `IPv6`, or `TURN`);
- latency, frame rate, resolution, bitrate, loss, codec, and decoder/encoder
  diagnostics in a quality popover;
- reconnect and ICE restart without leaving the screen;
- visible release-input shortcut and immediate emergency disconnect;
- permission guidance linked to the exact host capability reason.

Closing the Mac app, stopping the view, or losing the lease ends capture after
a short reconnect grace period. Unlike terminal sessions, remote desktop
capture is ephemeral and must not remain alive indefinitely.

## 9. Security and privacy

1. Preserve Dieter's binary full-access model; do not add pseudo-scopes.

2. Require an explicit per-machine remote-desktop enablement setting plus OS
   capture/control permission. View-only may be enabled separately from
   control, but this is a local safety setting rather than an account scope.

3. Authenticate every session through the existing daemon-bound token and
   bind the helper DTLS fingerprint to the enrolled daemon Ed25519 identity.

4. Protect helper IPC with filesystem/named-pipe ACLs and a one-time inherited
   secret. Never expose the helper's control socket to the network.

5. Do not log SDP, ICE candidate addresses, frames, input contents, clipboard
   contents, or TURN credentials. Store a local audit summary containing
   operator identity, daemon/session IDs, start/end times, route class,
   control/view-only state, and aggregate quality only.

6. Show a persistent local sharing indicator and a stop control on the host.

7. Bound all candidates, signaling messages, SCTP channel buffers, IPC queues,
   encoder queues, and concurrent sessions. Drop stale frames and pointer
   updates instead of accumulating latency.

8. Use short session and TURN expirations. An ICE transport remaining alive
   does not extend authorization without a daemon lease heartbeat.

9. Fuzz protobuf/data-channel decoders and validate all coordinates, sizes,
   cursor shapes, clipboard lengths, and key codes before platform injection.

## 10. Open-source assessment

### Google libwebrtc

- License: BSD-family plus dependency notices.
- Strengths: production ICE, congestion control, codecs, RTP recovery, native
  rendering, data channels, and desktop-capture modules for Linux/macOS/Windows.
- Risks: very large source checkout, GN/depot_tools build, binary size, API
  churn, patches that must be carried and audited.
- Decision: preferred production engine if the bake-off passes quality and
  maintenance gates.

Reference: <https://github.com/webrtc-sdk/webrtc/tree/m150_release/modules/desktop_capture>

### WebRTC-SDK fork

- License: BSD-3-Clause with Apache-licensed patches/notices.
- Strengths: active Google WebRTC fork with Apple/Mac improvements and useful
  desktop-capture patches.
- Risks: third-party fork and binary supply-chain ownership.
- Decision: prototype/reference source; production artifacts remain
  Dieter-built and pinned.

Reference: <https://github.com/webrtc-sdk/webrtc>

### Pion WebRTC

- License: MIT.
- Strengths: pure Go, active, full ICE/STUN/TURN/trickle/restart, SRTP,
  data channels, direct RTP/RTCP, H264/VP8/VP9 packetizers, NACK/TWCC/BWE
  building blocks.
- Risks: capture, production encoding, hardware acceleration, and feedback into
  encoder configuration remain application work.
- Decision: phase-one challenger and viable fallback architecture.

Reference: <https://github.com/pion/webrtc>

### coturn

- License: permissive BSD-family.
- Strengths: mature STUN/TURN, UDP/TCP/TLS, TURN REST credentials, metrics,
  high-throughput deployment patterns.
- Risks: bandwidth cost, abuse surface, regional operation, certificate and
  port management.
- Decision: recommended fallback relay, isolated from the gateway.

Reference: <https://github.com/coturn/coturn>

### RustDesk

- License: AGPL-3.0 for the application and in-tree modules.
- Strengths: proven product interaction, capture/input/clipboard organization,
  multi-platform packaging, cursor behavior, direct/relay UX.
- Risks: its documented core uses its own rendezvous/direct TCP-hole-punch and
  relay architecture rather than being a drop-in WebRTC stack. Copying its
  in-tree code would force licensing consequences incompatible with continuing
  Dieter as a simple MIT project.
- Decision: benchmark and design reference only. Independently licensed
  dependencies require individual provenance review.

Reference: <https://github.com/rustdesk/rustdesk>

### libdatachannel

- License: MPL-2.0.
- Strengths: lightweight browser-compatible C/C++ ICE, TURN, data channels,
  and media transport across major platforms.
- Risks: no complete capture/encode/render solution and additional Swift/Go
  bridge ownership.
- Decision: not preferred over libwebrtc or Pion.

Reference: <https://github.com/paullouisageneau/libdatachannel>

### webrtc-rs

- License: MIT/Apache-2.0.
- Strengths: active async Rust WebRTC stack and clean Sans-I/O architecture.
- Risks: pre-1.0, new Rust runtime/toolchain in Dieter, and media capture and
  encoding remain unsolved.
- Decision: revisit only if the whole host helper becomes Rust.

Reference: <https://github.com/webrtc-rs/webrtc>

### xcap

- License: Apache-2.0.
- Strengths: small cross-platform Rust capture abstraction with active macOS,
  Windows, X11, and partial Wayland work.
- Risks: Wayland has unsupported scenarios; recording is still described as
  work in progress; no input, encoder, or WebRTC layer.
- Decision: acceptable capture spike, not the production foundation.

Reference: <https://github.com/nashaofu/xcap>

### GStreamer webrtcbin

- License: LGPL core plus plugin-specific obligations.
- Strengths: broad capture/codec pipeline support and useful Linux tooling.
- Risks: large runtime/plugin package, cross-platform distribution complexity,
  plugin licensing audit, and no input solution.
- Decision: experiment/diagnostic tool, not the primary product stack.

### LiveKit and other SFU systems

- Strengths: excellent conferencing SDKs, observability, and multi-party media.
- Risk: the normal topology deliberately sends all media through an SFU.
- Decision: inappropriate for direct one-to-one remote desktop. Do not add an
  SFU merely to obtain a Swift WebRTC wrapper.

## 11. Delivery plan

### Phase 1: architecture bake-off and end-to-end proof

Duration: 1-2 weeks.

Build contained experiments rather than modifying product APIs or UI:

1. Pion end-to-end vertical slice:
   - actual desktop capture through an external FFmpeg process;
   - VP8 over a real WebRTC video track;
   - browser viewer and Metal/Swift viewer feasibility notes;
   - direct host ICE and optional STUN/TURN configuration;
   - data-channel RTT probe;
   - deterministic synthetic source for automated transport tests;
   - candidate-pair and connection-state diagnostics.

2. libwebrtc artifact spike:
   - reproducible pinned build notes for macOS XCFramework and host binary;
   - basic host PeerConnection plus desktop-capture module;
   - capture/encode/render proof on macOS;
   - compile feasibility on Windows and Linux/Wayland.

3. Compare:
   - time to first frame;
   - 1080p60 and 4K30 CPU/GPU use;
   - host and viewer memory;
   - binary and build size/time;
   - cursor-to-photon and glass-to-glass latency;
   - text quality at constrained bandwidth;
   - recovery under 1%, 3%, and 5% packet loss;
   - ICE restart and forced TURN/TLS;
   - implementation complexity and patch burden.

Phase-one exit gate:

- real screen visible end-to-end;
- first frame under 2 seconds after permissions on LAN;
- 1080p60 direct target on a modern Mac;
- successful ICE restart;
- successful TURN/UDP and TURN/TLS fallback;
- bounded memory under a 30-minute run;
- a written libwebrtc-versus-Pion decision record.

### Phase 2: control plane and Mac-to-Mac view-only

Duration: 2-3 weeks.

- add gateway RTC configuration and signed short-lived TURN credentials;
- add daemon capability/signaling/session RPCs;
- add helper lifecycle, local IPC authentication, session lease, and audit;
- build/pin the chosen WebRTC engine;
- implement ScreenCaptureKit display capture and video track;
- add Screens navigation, machine browser, display selection, and viewer;
- show route/quality state and permission guidance;
- add direct, gateway-signaled, and forced-TURN integration tests.

### Phase 3: Mac control-quality milestone

Duration: 2-3 weeks.

- input, pointer, cursor, and session channels;
- CGEvent injection and Accessibility onboarding;
- physical/logical keyboard protocol and all-keys-up safety;
- separate cursor shape/position with local rendering;
- reconnect, ICE restart, sleep/wake, display changes;
- adaptive bitrate/resolution/frame rate and quality UI;
- host sharing indicator and stop action;
- crash and orphan-session cleanup.

### Phase 4: Windows and Linux X11 hosts

Duration: 3-5 weeks.

- Windows per-user helper, DXGI capture, Media Foundation encoder, SendInput,
  packaging/signing/update path;
- Linux X11 capture/input and VAAPI/NVENC/software probes;
- shared platform capability model and conformance suite;
- multi-monitor, scale, rotation, cursor, keyboard layout, and reconnect tests;
- installer/service/user-session handoff on all platforms.

### Phase 5: Wayland and production hardening

Duration: 3-5 weeks.

- XDG RemoteDesktop/ScreenCast portal, PipeWire, and libei;
- restore-token and permission renewal behavior;
- NAT/carrier/enterprise firewall test matrix;
- regional TURN, quotas, abuse prevention, metrics, and cost dashboards;
- memory, queue, and concurrency bounds;
- fuzzing and security review;
- notarization, code signing, SBOMs, notices, and deterministic builds;
- accessibility and native UI smoke coverage.

Estimated production effort: 13-18 engineer-weeks, or approximately 8-12
calendar weeks with one engineer focused on media/platform work and another on
Mac/control-plane/product work.

## 12. Quality gates

Target metrics, measured separately for direct and TURN paths:

- p95 first frame below 2 seconds after permission is already granted;
- 1080p60 and 4K30 available when encoder/network permit;
- median pointer response below 35 ms and p95 below 80 ms on a healthy LAN;
- p95 ICE restart recovery below 3 seconds after a network transition;
- no stuck keys or buttons after focus loss, sleep, crash, or reconnect;
- host hardware-encode CPU below 20% on the supported benchmark machine;
- no unbounded frame, data-channel, signaling, IPC, or TURN queues;
- successful forced TURN/UDP and TURN/TLS sessions;
- direct candidate-pair selection for the majority of eligible sessions;
- 30-minute soak with stable memory and no growing goroutine/thread count;
- text remains readable under the defined constrained-bandwidth profile.

## 13. Test strategy

- Unit tests for signaling limits, session state machines, coordinate mapping,
  keyboard translation, permission capability mapping, and lease expiry.

- In-process Pion/libwebrtc transport tests using synthetic frames and data
  channels.

- Golden tests for cursor shape/hotspot, scaling, rotations, and multi-display
  coordinate spaces.

- Native integration runners for ScreenCaptureKit, DXGI, X11, and Wayland
  portal sessions.

- Network impairment tests with delay, jitter, bandwidth caps, reordering, and
  packet loss.

- NAT tests covering LAN, IPv4 NAT, IPv6, symmetric NAT, UDP blocked, TCP only,
  TLS 443 only, and interface changes.

- Security tests for expired/foreign tokens, fingerprint substitution, helper
  IPC access, oversized SDP/candidates, malformed data messages, stale input,
  TURN credential expiry, and replay.

- UI smoke tests for sidebar placement, permission states, display selection,
  full-screen/release-input behavior, route labels, reconnect, and screen stop.

## 14. Explicit first-release exclusions

- macOS login/FileVault/locked screens;
- Windows sign-in and UAC secure desktop;
- portable unattended Wayland and headless Linux;
- system audio;
- multiple viewers/controllers;
- large file transfer;
- HDR/wide color;
- H265;
- mobile viewers.

These are future milestones, not hidden requirements inside the initial screen
sharing release.

## 15. References

- Apple ScreenCaptureKit: <https://developer.apple.com/documentation/screencapturekit>
- Windows Desktop Duplication: <https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api>
- Windows SendInput: <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput>
- XDG RemoteDesktop portal: <https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html>
- Pion WebRTC: <https://github.com/pion/webrtc>
- Google WebRTC desktop capture tree: <https://github.com/webrtc-sdk/webrtc/tree/m150_release/modules/desktop_capture>
- coturn: <https://github.com/coturn/coturn>
- RustDesk: <https://github.com/rustdesk/rustdesk>
- libdatachannel: <https://github.com/paullouisageneau/libdatachannel>
- webrtc-rs: <https://github.com/webrtc-rs/webrtc>
- xcap: <https://github.com/nashaofu/xcap>
