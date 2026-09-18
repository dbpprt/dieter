# iOS remote screen access plan

Status: the first usable H.264 implementation is in the working tree. It covers
authenticated direct/relay signaling, signed session binding, video, cursor,
control/input, stream settings, control handoff, explicit text clipboard,
foreground teardown/reconnect, and adaptive iPhone orientation with floating
tap-to-toggle controls. The route factory and signed-binding verifier are shared
with Mac; device/fixture qualification and the later shared peer/Metal engine,
HEVC, and binary clipboard work remain rollout steps below.

## Outcome

Add an iPhone and iPad remote-screen viewer for an enrolled Dieter machine. The
finished feature should provide live video, authenticated control, touch and
keyboard input, display and quality selection, control handoff, foreground
recovery, and explicit clipboard operations through the existing screen-sharing
protocol.

This plan is for viewing and controlling a remote Mac from iOS. Capturing or
sharing the iPhone/iPad screen is not part of the work.

The first release should support one iOS screen session at a time, scoped to the
selected machine. Mac can retain its multi-session model. A mobile client should
close its screen session when the user leaves Screens, signs out, changes
machines, or backgrounds the app, then create a fresh authenticated session when
the user returns. iOS must not attempt indefinite background media or input.

## Repository findings

- The daemon and protobuf contract already expose capabilities, settings,
  signaling, session state, control handoff, live configuration, clipboard, and
  close operations. No daemon or schema change is required for the initial iOS
  implementation.
- `DieterClient` already contains `ScreenSignalingRPC`,
  `RemoteDesktopSignalingConnection`, direct-TLS/relay route selection, RTC
  configuration lookup, and direct-credential refresh.
- The iOS app already authenticates through the gateway, selects an enrolled
  machine, verifies direct TLS identity, falls back to relay, and tears down
  foreground RPCs on backgrounding. It has no screen connection factory or
  Screens destination yet.
- The pinned WebRTC XCFramework is linked only into the `DieterMac` executable.
  `DieterIOS` does not currently depend on WebRTC.
- The Mac screen client has the complete Apple implementation: signed binding
  verification, H.264/HEVC decoding, decoded-reference recovery, receiver
  feedback, bounded Metal presentation, control sequencing, clipboard,
  configuration, and reconnection. The session controller currently mixes those
  portable responsibilities with AppKit cursor, pasteboard, window, and
  sleep/wake APIs.
- Android already defines a suitable mobile interaction model: one-finger remote
  pointer, tap/double-tap/click-drag, two-finger local pan/zoom, three-finger
  remote scroll, software keyboard, modifier/special-key bar, fit-to-screen,
  explicit copy/paste, control handoff, and resume recovery.
- The iOS app already declares local-network usage and permits local networking,
  so direct LAN routes do not need a new entitlement or Info.plist purpose string.

## Target architecture

Do not copy the Mac controller into the iOS target. The signed session binding,
input epochs and sequences, codec fallback, feedback, recovery, and teardown are
security- and correctness-sensitive and should have one Apple implementation.

```text
Mac SwiftUI/AppKit adapters ─┐
                            ├─ DieterAppleScreens ─ DieterClient ─ daemon signaling
iOS SwiftUI/UIKit adapters ─┘          │
                                       └─ native WebRTC media/data channels
```

Add a package target such as `DieterAppleScreens`, depending on `DieterAPI`,
`DieterCore`, `DieterClient`, and `WebRTC`. Both `DieterMac` and `DieterIOS`
depend on it. Keep the target internal to the package unless a public product is
actually needed.

The shared target should own:

- offer/answer construction, ICE signaling, signed binding verification, and
  peer/session generations;
- H.264 and hardware HEVC decoder selection and automatic fallback;
- pointer/state/host/clipboard channel framing, input ordering, input epochs,
  control generations, and `releaseAll` behavior;
- receiver statistics, heartbeat, decoded-reference acknowledgements, adaptive
  recovery, session configuration, and reconnect policy;
- the bounded latest-frame Metal renderer, render mailbox, and presentation
  timing, using `CAMetalLayer` rather than an AppKit view;
- a platform-neutral observable session state and commands.

Thin platform adapters should own:

- Mac: `NSView`, `NSCursor`, `NSEvent`, `NSPasteboard`, `NSWorkspace` sleep/wake,
  and current window-focus behavior;
- iOS: `UIView`, touch/gesture recognition, `UIKeyInput`/hardware key presses,
  remote-cursor overlay, `UIPasteboard` or system paste controls, and scene
  lifecycle behavior.

The extraction must preserve Mac behavior before adding iOS behavior. This is a
useful regression boundary: if the shared core cannot run the existing Mac screen
tests unchanged, the split is not complete.

## Work packages

### 1. Prove dependency and packaging feasibility

1. Confirm that the pinned WebRTC XCFramework contains supported arm64 device
   and Simulator slices and imports from an iOS SwiftPM target.
2. Link a minimal WebRTC reference through `DieterIOS`, build Simulator and
   unsigned device configurations, and create an unsigned archive.
3. Inspect the resulting app for embedded-framework signing, duplicate symbols,
   minimum OS compatibility, license notices, privacy manifests, and App Store
   packaging issues.
4. Add the `DieterAppleScreens` and `DieterAppleScreensTests` targets without
   changing runtime behavior.

Exit: Simulator, arm64 device, and archive builds all link WebRTC reproducibly.
If the current binary is not distributable on iOS, resolve the dependency before
building feature code; do not maintain a second media stack as a workaround.

### 2. Extract the shared Apple screen core without behavior changes

Move the platform-neutral pieces from `apps/mac/Sources/DieterMac/Networking/`
into the shared target. Start with trust, recovery, feedback, reference recovery,
decoder selection, render mailbox/executor, and Metal renderer. Then split the
current controller into a shared peer/session engine plus AppKit adapters.

Preserve these invariants during the split:

- accept video/control only after the certificate-backed signature binds the
  nonce, offer hash, DTLS fingerprint, display, protocol version, control grant,
  and 16-byte input epoch;
- arm input only after a frame from the advertised display generation has been
  decoded and presented;
- scope every callback, candidate, channel, and delayed task to the current
  session generation;
- release held keys/buttons before control loss, backgrounding, reconnect, codec
  change, display change, or teardown;
- keep pointer movement coalesced and stateful input reliable and ordered;
- never replay an uncertain clipboard paste or stale input after reconnect;
- keep one decoded frame pending, invalidate old render generations, and avoid
  blocking the main actor on decode or Metal presentation;
- retain independent signaling routes and credential refresh so a screen failure
  cannot tear down task/conversation observation.

Move the existing Mac unit tests with the implementation where possible. Keep
AppKit-specific tests in `DieterMacTests`. Run the current native Mac screen
fixture after the extraction and require no latency, recovery, input, clipboard,
or codec regression.

Exit: Mac behavior and tests are unchanged, and the shared session engine has no
AppKit import.

### 3. Add the iOS route, ownership model, and view-only viewer

Add a reusable screen-connection factory in `DieterClient` rather than duplicating
the Mac route sequence in `IOSStore`. Given the gateway origin/token and selected
machine, it should:

1. reject missing, incompatible, or offline machine identities;
2. resolve the authenticated daemon route and RTC configuration;
3. select verified direct TLS first and bounded relay second;
4. refresh a direct credential for a long-lived screen connection;
5. return the daemon certificate, signaling RPC, RTC configuration, route label,
   and one idempotent shutdown operation.

Add a `Screens` destination to the iOS sidebar. On iPhone it opens a full-screen
stack destination; on iPad it occupies the detail column. The session owner
should survive SwiftUI redraws and rotation, but not machine changes, sign-out,
leaving Screens, or backgrounding.

Build the iOS viewer with:

- explicit Connect/Disconnect and a visible connecting/reconnecting/failed state;
- an explicit Enable & Connect action only when the host reports sharing disabled;
  merely opening Screens must never change daemon policy;
- H.264 as the compatibility baseline, initially capped at 1920×1080 and 60 fps;
- a `UIView`/`UIViewRepresentable` surface backed by the shared `CAMetalLayer`
  renderer, with aspect-fit layout, safe-area handling, rotation, and split-view
  resizing;
- route, resolution, actual FPS, media route, and view-only/control status;
- a remote cursor overlay tied to the current display generation.

Use a generic client label such as `iOS`, not the device's user-assigned name.
Do not log SDP, clipboard content, decoded pixels, or input text.

Exit: a real iPhone/iPad or the isolated native fixture can establish an
authenticated H.264 session, render changing pixels, rotate/resize safely, and
disconnect without leaking a peer, route, timer, or renderer.

### 4. Add control and mobile input

Implement input in a dedicated UIKit canvas instead of stacking competing
SwiftUI gestures. Match the established Android behavior:

- one finger moves the remote pointer relative to the fitted canvas;
- tap and double tap send left click/double click;
- long-press then move performs a drag and always releases on cancellation;
- two fingers pan and zoom the local canvas without moving the remote pointer;
- three fingers send remote scroll with phase and momentum where UIKit provides
  them;
- a Fit action resets local pan/zoom;
- a bottom bar exposes keyboard, modifiers, arrows/navigation/function keys,
  right click, and refresh;
- software keyboard composition sends UTF-8 text, while special and hardware
  keys use the existing HID mapping and key-down/key-up channel;
- iPad pointer/trackpad events are supported without changing touch semantics.

Control remains disabled until the signed grant is valid and the expected frame
has been presented. Show who controls the machine, viewer count, Take Control,
and Release Control when protocol 3 supports handoff. A view-only client must not
send input or read/write clipboard data.

On scene inactivity/background, resign first responder, send `releaseAll`, stop
clipboard work, close the peer and signaling route, and cover the last frame so it
does not appear in the app-switcher snapshot. On foreground, reconnect only when
Screens is still the active destination and require a new signed binding, epoch,
and control state.

Exit: pointer, clicks, drag, scroll, text, modifiers, special keys, hardware
keyboard, control handoff, and interruption cleanup pass against the isolated
input fixture.

### 5. Add stream controls, codecs, and clipboard

Expose display, Automatic/Detail/Motion quality, 30/60 fps, refresh, and codec
selection. Keep H.264 as the initial default. Enable Automatic/HEVC only when the
device reports hardware HEVC decode and the existing strict negotiation succeeds;
reuse the Mac one-time HEVC-to-H.264 fallback and generation reset. Higher mobile
frame-rate choices should remain hidden until measured on physical devices.

Clipboard should be explicit and foreground-only on iOS:

- Copy asks the remote host to copy, then writes the returned supported content
  to the local pasteboard;
- Paste uses an iOS system paste interaction/control so local pasteboard access
  is visibly user initiated, then sends one non-retriable remote paste operation;
- support text first, then PNG/JPEG and regular-file payloads within the existing
  8 MiB/64-file bounds using app-private staging;
- never poll or overwrite the local pasteboard merely because control was granted;
- keep operation IDs, control generations, input barriers, bounded 16 KiB frames,
  timeouts, and stale-grant rejection identical to the existing clients.

Exit: display/quality changes, codec reconnect/fallback, text/image/file
copy-paste, interrupted transfers, and stale-control rejection pass without
affecting the video session on a simple permission denial.

### 6. Verification and rollout

Add focused coverage at each layer:

- Shared unit tests: every signed-binding field, expired/tampered certificates,
  stale session generations, recovery classification/backoff, feedback freshness,
  decoded references, renderer mailbox bounds, H.264/HEVC selection, and teardown.
- iOS unit tests: session ownership, foreground transitions, navigation/machine
  changes, coordinate transforms, gesture state machines, HID/modifier ordering,
  clipboard limits, and app-switcher privacy state.
- iOS UI tests: Screens navigation on phone/iPad, disabled/offline/error states,
  connect/disconnect, options, control handoff UI, keyboard/special keys, rotation,
  and Dynamic Type/accessibility labels.
- Actual WebRTC fixture: synthetic changing frames plus pixel verification,
  authenticated input round trips, display switching, transient signaling loss,
  native capture loss, foreground recovery, and explicit-disconnect cancellation.
- Cross-client tests: iOS plus Mac/Android viewers, protocol-3 control handoff,
  independent quality changes, and the four-client/encoder limits.
- Physical-device qualification: H.264 and HEVC hardware decode identity,
  first-frame time, input-to-presentation median/p95, render cadence, memory,
  CPU/GPU, thermal behavior, battery impact, Wi-Fi/cellular/TURN behavior, and a
  30-minute reconnect/control soak. Simulator results are not evidence for power,
  thermals, hardware decode, or touch latency.
- Regression: `just check-changed --dry-run`, `just check-changed`, existing Mac
  and Android screen suites, `just ios build`, `just ios build-device`, iPhone and
  iPad smoke, and unsigned archive validation. Use only disposable daemon/gateway
  fixtures and never stop an operator's app or daemon.

Update the iOS README and validation notes, top-level screen-sharing documentation,
Apple release notes/privacy disclosures, and the Dieter CLI skill's client-support
description once the feature is real. If implementation discovers a necessary
RPC change, apply the repository's full proto/core/Connect/CLI/help/generated
client/local/direct/relay parity rule rather than adding an iOS-only endpoint.

Roll out first to internal TestFlight with H.264 as the default. Promote Automatic
HEVC and any frame rate above 60 only after physical-device measurements meet the
existing screen latency/recovery expectations. Rollback is hiding the iOS Screens
entry or forcing H.264; there is no data migration.

## Definition of done

- An enrolled, compatible online machine can be selected and its screen opened
  from both iPhone and iPad over verified direct TLS or authenticated relay
  signaling, with WebRTC media using ICE/TURN as configured.
- Video, cursor, input, control handoff, display/quality selection, reconnect,
  and explicit clipboard operations work on a physical device.
- Backgrounding, sign-out, machine changes, leaving Screens, and explicit
  Disconnect release input and all session resources; returning never reuses a
  stale grant, epoch, route, or clipboard mutation.
- Invalid identity, signature, binding, or protocol data cannot produce video
  control or clipboard access.
- Existing Mac and Android remote-screen behavior remains passing after the
  shared Apple refactor.
- Device, Simulator, archive, focused screen, and affected repository checks pass,
  with physical-device performance and TestFlight packaging evidence recorded.

## Recommended implementation order

Land this as reviewable increments: WebRTC/iOS feasibility; shared Apple core with
Mac unchanged; iOS view-only route and renderer; input/control/lifecycle;
configuration/codec/clipboard; then end-to-end qualification and TestFlight
rollout. The first externally useful milestone is H.264 view plus basic control,
but it should not be described as complete remote screen access until lifecycle,
security, recovery, and physical-device checks also pass.
