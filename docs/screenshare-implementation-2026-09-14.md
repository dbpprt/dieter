> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Native Mac screen sharing implementation — 14 September 2026

Dieter now has a native, adaptive Mac screen and input pipeline. This implements the Mac scope of the [assessment](screenshare-assessment-2026-09-13.md): ScreenCaptureKit → hardware VideoToolbox H.264 → bounded Pion/WebRTC transport → native libwebrtc/Metal display, with a separate cursor and reliable stateful input. Linux capture remains explicitly unsupported behind a portable backend contract.

## Capture and transport

The helper passes ScreenCaptureKit's NV12 `CVPixelBuffer` directly to VideoToolbox. Raw screen pixels stay inside the native capture/encode process. Hardware encoding is required; the encoder uses the low-latency H.264 High path where negotiated, with hardware Baseline compatibility, no frame reordering, and a bounded pending raw frame. FFmpeg implementations, environment configuration and CLI branches have been removed. No FFmpeg subprocess, library wrapper, raw-pixel Go conversion, JPEG stream or browser renderer is used by this pipeline.

The versioned `DTH2` binary framing carries frame identity, display generation, monotonic presentation time, dimensions, keyframe status, capture/encode timings and drops. RTP timestamps follow that real timeline, including idle gaps, refreshes and skipped frames. Configuration changes restart capture/encoding only when needed; FPS, bitrate and embedded cursor updates can happen live. Reconfiguration from commands, display topology and cursor fallback is serialized with a bounded wait list.

The daemon drains encoded output continuously, retains one pending access unit, and lets its packet pacer apply backpressure to the sender. It drops obsolete work at frame boundaries and requests an IDR before continuing a broken reference chain. The pacer has no growing packet queue. Retransmission uses one worker, 64 pending requests, at most four 512-packet histories, 250 ms packet retention and two retries. Loss testing exposed a shared RTP-header race in Pion's default NACK path; Dieter's bounded retransmission adapter owns a cloned header for each send.

The helper's acknowledged command/event descriptor is separate from video. Commands and writes have deadlines. A missing daemon heartbeat releases input and stops capture; EOF, graceful termination, disconnect and focus loss also release held input. The helper releases input before signaling final process completion.

## Adaptive behavior

The viewer requests its actual backing-pixel viewport, up to 3840×2160, 60 fps and 12 Mbps by default. These are ceilings, not guaranteed output. Hardware capability and H.264 negotiation are explicit; the Mac decoder advertises the hardware-supported profiles and appropriate level rather than the old 1080p-inadequate default level.

Transport-wide feedback drives Pion's send-side GCC bandwidth estimator. A 500 ms policy combines its budget with encoder cost, send duration and receiver decode, jitter-buffer and loss evidence. Bitrate reserves transport headroom; repeated pressure reduces FPS; sustained recovery raises it. Spatial changes use slower hysteresis and quantized dimensions. Automatic, sharp-text and smooth-motion preferences retain user ceilings. Static ScreenCaptureKit content stays idle; refresh re-encodes retained pixels with a new presentation timestamp. Status reports applied geometry, FPS, bitrate, encoder and queue timings, drops, receiver progress and input acknowledgments. The viewer distinguishes signaling route from the actual selected direct/TURN media route.

The first keyframe of a display generation establishes an RTP boundary. Input becomes active only after Metal presents that generation. RPC responses and host events use the same state application logic, so crossing response order cannot arm control for an old display. This also handles RTP timestamp wrap and frames that arrive before their metadata.

## Native rendering

The Mac viewer maps decoded NV12 IOSurfaces directly into Metal luma/chroma textures, with GPU YCbCr conversion, aspect fitting and rotation. It also accepts native BGRA buffers. It never requests an I420 CPU conversion. One GPU submission and one replaceable pending decoded frame bound renderer work; frame arrival triggers drawing, with no idle redraw timer. Reset invalidates queued work and late presentation callbacks. Receiver FPS and display-generation readiness now use actual drawable presentation, while decode cost continues to use libwebrtc's decode statistics.

A runtime probe of the pinned `RTCMTLNSVideoView` found a 30 Hz timer and an unconditional NV12-to-I420 conversion. Dieter's replacement removes both. The focused native integration test presented **60.0 fps** at 960×540 over two seconds, verified zero calls to `toI420()`, coalesced a 1,000-frame burst, and verified no redraws while idle. This is measured presentation on this host, not cross-machine input-to-photon latency.

## Cursor and input

Cursor shape, hotspot, visibility, position and last applied input ordinal are separate from video. The controlling viewer draws its pointer locally; passive viewing follows host position. PNG payload and cache sizes are bounded. The public Mac cursor API sometimes supplies a 10× image representation; the helper rasterizes the logical cursor at 2× instead of sending that oversized representation. Embedded capture remains an explicit fallback if extraction is unavailable.

Input protocol v2 fixes missing zero/false scalar values, including Mac key code zero, key-up, mouse-up and screen-edge coordinates. It adds USB HID physical keys, independent modifier-side tracking, repeat semantics, committed Unicode text, fractional precise scroll deltas and scroll/momentum phases. Dragging continues to deliver a release outside the video rectangle. Reliable key/button/scroll state and discardable pointer motion share an event ordinal and ordering barrier, preventing an old pointer packet from undoing a newer click.

The native viewer owns shortcut routing while focused, supports optional local IME composition through `NSTextInputClient`, and releases input on app/window focus loss. Command-Shift-Escape releases focus. A reliable-channel failure is visible and closes the session instead of silently losing a release. Display coordinates include negative origins and generation checks; the helper rejects stale geometry.

## API, CLI and portability

`GetRemoteDesktopSession` and `UpdateRemoteDesktopSession` are explicit core RPCs with thin Connect adapters and generated Go/Swift clients. Capabilities enumerate actual displays and permissions passively. CLI parity includes:

```sh
dieter screen capabilities
dieter screen status SESSION
dieter screen configure SESSION --quality detail --fps 30 --bitrate 8000
dieter screen configure SESSION --display DISPLAY_ID
dieter screen refresh SESSION
```

Unspecified configure flags preserve existing ceilings. Local loopback, verified direct TLS and authenticated gateway relay command routes are tested. The authenticated offer/certificate/input binding is retained; protocol v2 requires matching daemon and Mac client builds.

The generic Go backend contracts expose capabilities, encoded frames, configuration, input and source events without Mac handles. A later Linux implementation can use PipeWire/portal capture, compositor-native input and native hardware encoding behind those contracts. It does not need a transport or viewer rewrite. No Linux capture or Linux input backend is claimed here.

RustDesk informed the separation of cursor services, adaptive quality, pressed-state ownership and platform adapters. No RustDesk source was copied and it is not a dependency. Its codec/FFmpeg plumbing was not adopted. The pinned source references and rationale are retained in the assessment.

## Validation

Validation uses the Apple M4 Mac on macOS 26.5.1, temporary daemon homes, random loopback listeners, ephemeral signing identities and owned fixture processes. The installed Dieter daemon is not restarted or replaced.

These results were collected before integrating upstream commit `174dc7b2` (TestFlight provisioning and native smoke reliability). That commit was incorporated without conflicts before publishing this change. The broader UI smoke failures below describe the recorded run; those suites have not been rerun with the upstream smoke fixes.

- Real ScreenCaptureKit → VideoToolbox → daemon → authenticated signaling → native WebRTC decoder → Metal window passes. The test receives actual posted keyboard and mouse events in an owned AppKit window, changes quality, switches to a second display at a negative origin and tears down its processes. A real window screenshot verifies Metal output rather than relying on a bitmap snapshot that omits GPU content.
- Native helper regression exercises actual hardware H.264 encoding, scalar interoperability, live dimensions/FPS changes, stale-display rejection, idle refresh timing, input under blocked video consumption, heartbeat expiry and process reaping. Generated NV12 and dry-run injection make the default test independent of desktop permissions.
- A virtual Pion network exercises TWCC/GCC and the production pacer under latency, jitter and a bandwidth collapse to 800 kbps. It asserts budget reduction, bounded reliable-control response and cancellation; repeated race-detector runs pass. This is simulated network evidence, not a two-machine WAN benchmark.
- CLI route integration covers local, direct TLS and relay status/configure/refresh operations. Protocol tests cover invalid bindings, bounds, stale epochs, cursor/input framing and configuration behavior. Native viewer tests cover letterboxing, outside-window drag geometry, scroll phase mapping and display-frame readiness.

Measured in the hardware fixture: **60.1 fps at 1920×1080**, with **5.63 ms mean encode time** over 60 frames after warmup, using changing synthetic NV12. This measures the native encode path, not end-to-end glass-to-glass latency. During the impaired-network test, GCC reduced its estimate from 4.41 Mbps to 1.13 Mbps while reliable control completed a round trip in 33.34 ms; three earlier race runs reached approximately 0.95–0.98 Mbps with 34–42 ms control RTT.

The full Go race suite and `go vet` passed; after the last negotiation-watchdog fix, the affected remote-desktop/server/CLI/gateway race suites passed again. The complete Swift package suite passed **582 tests**, including another full run after the Metal renderer change, Android unit tests passed, Swift formatting passed, and the remote-desktop package cross-compiled for Linux/amd64. This is compile compatibility, not a Linux implementation.

`just check-changed --dry-run` and `just check-changed` selected the broader shared-schema checks. The aggregate run reached the iOS build and stopped in Xcode's Keychain dependency resolver. Retrying with the public-download `netrc` provider resolved the packages, then established that the required iOS 26.5 Simulator platform is not installed. iOS build/simulator smoke checks are therefore unavailable on this installation. Android emulator startup also refused safely: 3461 MiB reclaimable memory was below the standard AVD's 6144 MiB renderer safety margin. No emulator was launched and the attached physical phone was not used. Android instrumentation is unavailable under that constraint.

The final native-helper regression passes (including heartbeat expiry and delayed ICE negotiation), and the final synthetic native-viewer run passes all eight focused tests. It decoded **59.8 fps at 960×540** and observed the native input acknowledgment within **27 ms** on loopback. The acknowledgment observation includes the test's polling interval; it is not a measured input-to-photon latency.

After Keychain was cleared, the expanded real-desktop rerun passed **all eight focused tests**. It verified capture/decode/Metal output, separate cursor delivery, actual mouse-up and key-code-zero down/up, committed `é漢字🙂` text, precise scrolling, held-key release, live quality, second-display switching with new-frame control gating, and teardown. The target's recorded events and the Metal screenshot were inspected. The replacement NV12 Metal renderer then passed all eight tests again, including queued-draw invalidation on disconnect. The earlier focus-guard failures sent no input and were caused by the host Keychain dialog; that blocker is resolved. The packaged core (including Screens), board, machine and island smoke suites passed. Broader smoke checks currently fail in conversation code-link navigation, HTML export and terminal output, plus sidebar hover actions and aggregate terminal-machine restoration after a client restart. These failures are outside the focused screen-share journeys; their causes have not been assigned to this change. The terminal suite otherwise verified input, scrollback, selection/copy/paste, resizing and continued input after restart. The workspace suite fails mixed-staging presentation and horizontal scrolling of split diffs. There are seven failing assertions across these broader UI suites; the overall packaged-app smoke run is not green.

Some in-app bitmap smoke snapshots also contain artifacts around transparent surfaces (white sidebar and an unusable island snapshot). They do not establish composited visual correctness. The screen viewer was instead inspected using a real WindowServer screenshot.

The Mac debug app builds and passes ad-hoc signature verification at `apps/mac/build/Dieter.app`; canonical build/test caches were reused. The installed daemon was neither replaced nor restarted, no operator Dieter process was stopped, and all screen fixture/helper/input-target processes were reaped. The final process check found zero DieterMac, capture-helper, screen-fixture or input-target processes. The finished code requires matching daemon/helper and Mac client builds before using it against the installed service.

Evidence retained on this machine:

- [Native hardware throughput and impaired-network results](/tmp/dieter-screens-implementation/performance.log)
- [Direct NV12 and actual Metal presentation regression](/tmp/dieter-screens-implementation/metal-viewer-final.log)
- [Final synthetic native-viewer test](/tmp/dieter-screens-implementation/mac-synthetic-final.log)
- [Final real desktop/input and direct Metal success](/tmp/dieter-screens-implementation/metal-real-final.log)
- [Full Swift regression after Metal change](/tmp/dieter-screens-implementation/mac-tests-metal.log)
- [Real Metal window screenshot](/var/folders/nk/8324zqs10fq249x2ythzxc540000gn/T/dieter-screen-viewer-75B14A42-92EA-4537-87C6-6FA301EC60C6/viewer.png)
- [Final affected Go race suites](/tmp/dieter-screens-implementation/go-final.log)
- [Packaged core, board and conversation smoke](/tmp/dieter-screens-implementation/mac-smoke-resumed.log)
- [Packaged machine and sidebar smoke](/tmp/dieter-screens-implementation/mac-smoke-remaining.log)
- [Packaged terminal lifecycle smoke](/tmp/dieter-screens-implementation/mac-smoke-last.log)
- [Packaged island and workspace smoke](/tmp/dieter-screens-implementation/mac-smoke-island-workspace.log)
- [Shared-schema aggregate checks](/tmp/dieter-screens-implementation/check-changed-final.log)
- [iOS SDK limitation](/tmp/dieter-screens-implementation/ios-build.log), [Android memory preflight](/tmp/dieter-screens-implementation/android-start.log)


Reproduce the screen-specific checks:

```sh
just mac screens-native-test
just mac screens-test
DIETER_TEST_SCREEN_CAPTURE_REAL=1 just mac screens-test
```

The real-input variant requires existing Screen Recording and event-posting permission. It waits for its own target window to become active before sending input. Viewer integration refuses to run beside an operator Dieter app. Test evidence directories are printed in the output.

## Practical limits

The implementation provides the requested native Mac architecture and adaptive/control mechanisms. It does not establish every performance target from the assessment. Loopback tests and synthetic network impairment are not measurements of real LAN/WAN motion-to-photon latency, 4K60 throughput, battery use or long-duration thermal behavior. Retina scaling, physical hot unplug, sleep/wake, secure input, every third-party IME and every keyboard layout still require a broader hardware acceptance matrix. macOS can reserve shortcuts before Dieter receives them.

Separate cursor extraction currently uses the public `NSCursor.currentSystem` API, which the installed SDK marks for future deprecation; the embedded fallback is retained for compatibility. Native encoding is SDR H.264, with 60 fps as the ceiling. Audio, clipboard synchronization, file transfer, HDR, 120 fps and Linux implementation are outside this Mac screen/input change. Existing native-app platform and packaging requirements remain in effect.

The checked-in WebRTC binary links Apple frameworks and exposes no FFmpeg symbols in the inspected symbol table. That inspection supports the active native path; it is not a complete provenance audit of every stripped byte in the third-party prebuilt framework. No new binary dependency or dependency version upgrade was introduced.

## Remaining screen-sharing acceptance work

1. Measure two physical Macs over LAN, Wi-Fi and WAN, including forced TURN media relay, NAT traversal and reconnects. Existing CLI gateway-relay coverage does not prove the TURN video path. Record input-to-photon and capture-to-display percentiles with a shared measurement method; the current encoder timings and acknowledgment RTTs do not establish those latencies.
2. Exercise the native decoder while real network bandwidth collapses and recovers, including large keyframes, long idle periods and resumed motion. The current virtual-network test validates transport adaptation and independent control delivery; it does not decode the impaired video or simulate a shared bottleneck for every traffic class.
3. Run sustained 4K60 content, text readability and CPU/GPU/power/thermal measurements. The measured 1080p hardware encode rate is not a 4K60 guarantee or a long-session resource profile.
4. Complete hardware acceptance for Retina/mixed-scale displays, rotation, physical unplug/replug, sleep/wake/lock, secure input and representative keyboard layouts/IMEs. Generation checks and unit tests cover the mechanisms; these physical cases are not all verified.
5. Roll out matching daemon, helper and Mac client builds using the normal signed packaging and permission flow. The operator's installed daemon is intentionally still the previous build.

Linux capture/input, audio, clipboard synchronization, file transfer, HDR and 120 Hz are future feature work rather than implemented capabilities. The immediate Mac screen/input implementation is functional; the items above remain before claiming measured native-like behavior across machines and networks.
