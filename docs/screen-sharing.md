# Screen-sharing engineering reference

Start with the [Screens user guide](../landingpage/content/docs/screens.md) for setup and controls.
This reference preserves protocol details, diagnostics, clipboard limits, and
qualification commands. Experimental flags describe disposable test processes,
not recommended production tuning.


In the Mac viewer, **Settings → General → Capture keyboard in fullscreen**
forwards system shortcuts such as Cmd-Tab while the fullscreen viewer has focus
and control. Allow Dieter in macOS Accessibility to enable interception. Keep
**Cmd-Shift-Escape** local to release input; click the video to capture again.
Cmd-Control-F is forwarded while captured and toggles Dieter's fullscreen window
after release. Focus loss, control loss, disconnection, or a disabled event tap
releases capture. Protected system input and hardware/system gestures are not
included. Ordinary input remains available when capture permission is denied.

**Settings → Experimental → Match remote resolution in fullscreen** is off by
default. It temporarily changes the selected remote monitor to the closest
supported desktop size and Retina scale, independently of encoded video ceilings.
This affects other viewers and anyone using that monitor. Only the controlling
session may change modes. Fullscreen exit, disabling the option, changing displays,
control handoff, and session closure restore the original mode. A subsequent local
mode change takes precedence. macOS also reverts the helper's app-scoped changes
when it exits; permanent display preferences are never written. Unsupported modes,
mirrored displays and helpers without mode-switching support leave streaming available with a status message.
Arbitrary virtual displays are not created.

The daemon CLI exposes the same experimental operations over local, direct TLS,
and relay routes. Use IDs from a fresh response; stale requests are rejected:

```sh
dieter screen resolution modes SESSION
dieter screen resolution set SESSION --display DISPLAY_ID --mode MODE_ID --expected-current CURRENT_MODE_ID
dieter screen resolution restore SESSION
```

Native command acknowledgments and heartbeats are independent of encoder
configuration and downstream cursor/state delivery. Keepalives run at a fixed
cadence without waiting for an individual reply; other acknowledged commands
also prove helper liveness. The three-second silent-helper/daemon bound remains
enforced, with command-age diagnostics and bounded client recovery after a native
capture interruption. A brief receiver heartbeat
gap releases held input and pauses control without closing video; fresh feedback
resumes control in the same session. Peer/signaling grace periods and the session
lease still bound disconnected sessions.
Fresh, epoch-validated WebRTC heartbeats renew that lease while the authenticated
signaling subscription remains open, so delayed unary renewals do not kill healthy
video. Detaching or revoking signaling still ends the share after its bounded
grace period. Mac renewal runs independently of the UI thread; recoverable session
expiry opens a fresh authenticated route with at most three backoff attempts.

Mac hosting uses ScreenCaptureKit and VideoToolbox H.264 or opt-in HEVC. Linux
hosting uses the companion native helper with in-process GStreamer: portal-selected
PipeWire capture on Wayland, XImage/XDamage capture on X11, H.264 hardware
encoders when qualified, and bounded x264/OpenH264 fallback. X11 control uses
XTest; Wayland control uses the standard RemoteDesktop portal notification API.
On a controlling Mac, the Linux capture stream hides its baked-in pointer and
the viewer draws the pointer locally, so mouse feedback does not wait for the
video round trip. View-only and touch-client sessions retain an embedded pointer.
The helper never runs as root, uses `/dev/uinput`, or sends raw desktop pixels to
the daemon. Portal source selection remains locally user-mediated. Linux text,
image/file clipboard transfer, separate cursor metadata, HEVC, and physical mode
switching are not advertised until their backend-specific contracts qualify.

On Android, one finger moves the remote cursor like a trackpad. Two fingers
continuously zoom and pan the desktop canvas in both axes, including below its
initial fit size. The point between the fingers follows the gesture; lifting and
replacing one finger resumes it without moving the remote cursor. A small visible
edge keeps the desktop reachable, and **Fit screen** restores the centered view.
These gestures transform the local GPU view without changing capture quality.
Three fingers scroll the remote screen; the bottom bar provides keyboard and
special keys.

The zoom strip shows the current size relative to fit: **100%** fits the desktop
to the available canvas. **−** and **+** make animated 25% zoom steps (25–800%);
repeated presses accumulate, and touching the canvas immediately takes over the
animation. Tap the percentage to fit and center again. The strip sits outside the
remote image so it cannot block a dock, taskbar, or remote button. Zooming does not
change capture resolution. Small tap movements leave the cursor still; a tap or
the bottom-bar **Click** acts at the cursor, not at the finger. Lifting a finger
after a pinch cannot produce a click. Physical mouse input ignores the letterbox,
deduplicates Android button events, forwards double clicks with matched press and
release counts, and releases drags even outside the image. A press that starts
outside the desktop cannot turn into a remote drag when the mouse moves inside.
Reconnects reset the displayed transform together with input coordinates.

Each Mac viewer session is a machine-scoped Screens tab. It remains connected when
the user navigates to another Dieter workspace, and the Screens sidebar count shows
currently live tabs. General settings provides an optional inactivity timeout,
disabled by default, with a 30-minute duration when enabled. Mouse, keyboard,
tab-selection, and screen-option activity reset it. System sleep pauses the timer;
waking resets it and immediately reconnects an open tab. A deliberately timed-out
connection can be reconnected from its tab.

The viewer follows its window’s pixel size, up to 3840×2160 at 60 fps and 12 Mbps
by default. Screen options and `dieter screen configure SESSION --fps 120` select
30/60/90/120 fps ceilings when advertised by the host. Rates above 60 use at most 1920×1080
to stay within the negotiated H.264 level. Actual cadence depends on capture,
encoder/decoder capacity and the viewer display. Hosts without high-frame-rate capability retain their advertised ceiling. The host adapts bitrate,
frame rate and resolution using transport-wide congestion feedback, encoder cost,
and fresh receiver decode/loss measurements. Automatic/detail modes lower cadence
before pixels and require at least 12 seconds between reductions. Responsive motion
mode reduces pixels first while above its 640-pixel floor, with sustained pressure
and at least four seconds between resizes; compute capacity still limits cadence. Recovery preserves measured headroom across quiet intervals
without counting idle time as capacity evidence. Low estimates alone do not remove
pixels; reductions require fresh loss or sustained transport queue growth. RTT
changes alone do not discard acknowledged bandwidth. Receiver heartbeats
carry independent measurement identities and ages, so stalled statistics cannot
replay an old overload sample. Deliberate packet pacing is not counted as congestion.
Bitrate and cadence updates keep the native encoder session alive. Transport returns
one frame credit after sending a complete H.264 access unit; while it waits, capture
retains only the newest raw surface. Pipe writes run independently of capture and
input. Mac renders on a dedicated thread from decoder completion, with one GPU
submission and one replaceable decoded frame. Android renders directly from
decoder completion; Mac callbacks are
bound to the renderer generation so a released decoder cannot draw into a new
session. Both viewers send the first pointer movement immediately and coalesce
subsequent movement over four milliseconds. Compatible receivers negotiate
immediate playout. Packet repair uses fresh RTT and frame cadence to bound useful
retransmissions (50–250 ms from the first packet, reserving outward transit time);
missing/stale timing retains the bounded compatibility window. Expired repair
requests trigger a rate-limited keyframe refresh. Healthy receivers permit
bounded recovery probes during active or resumed video: at most double the current
rate, 64 KiB / 250 ms, once per three seconds. Small RTP padding completes probes
after sparse frames. A degraded idle desktop requests a refresh at most once per
three seconds so acknowledged probes can restore bitrate and redraw a sharp image.
Silence alone never raises quality. Only actual transport acknowledgments establish
capacity; loss or sustained queue growth revokes it. The daemon
log records quality changes, sample age, delivered rate, queue growth and GCC state.
Screen options select a display,
prefer sharp text or smooth motion, or request an idle-screen refresh. Cursor shape,
hotspot and position travel separately from video. Temporary cursor-shape lookup
failures retain the last valid shape (or the initial arrow); embedded capture
remains an explicit compatibility option.
Physical USB HID keys, left/right modifiers, pointer dragging and precise scrolling
are supported. Enable local text composition in Screen options for IME input.
Focus loss releases held input; ⌘⇧Esc releases input locally. Fullscreen keyboard
capture forwards system shortcuts when Accessibility permission is available;
protected system input and hardware/system gestures remain local.
On Mac, clicking inside a streaming desktop also activates its window. Video and
host-cursor presentation layers pass all pointer input to the screen input view.

The CLI works on local, verified direct TLS and authenticated relay routes:

```sh
dieter screen capabilities
dieter screen permissions
dieter screen sessions
dieter screen control take <session-id>
dieter screen control release <session-id>
dieter screen status SESSION
dieter screen configure SESSION --quality detail --fps 30 --bitrate 8000
dieter screen configure SESSION --display DISPLAY_ID
dieter screen refresh SESSION
```

Configuration flags preserve unspecified values. Width, height, FPS and bitrate
are ceilings, not promises. `status` reports active dimensions, frame rate, bitrate,
encoder time, frame drops, display generation and input acknowledgments. Timing
fields separate socket work (`queueMs`), total paced send (`sendMs`), approximate
capture-to-send age (`captureToSendMs`, including encoder/pipe delivery), receiver
jitter-buffer residence (`jitterBufferMs`), and decoded-frame-to-output timing
(`renderMs`). `renderMeasurement` identifies actual Metal presentation on Mac or
EGL submission on Android. `pacingBitrateKbps` includes packet pacing headroom.
Receiver timings require advertised client measurements and use interval means;
zero may mean no new timed frame. These overlapping stages must not be summed as a
physical glass-to-glass measurement. The native fixture reports same-host capture
to actual Metal presentation median/p95 and idle recovery using the shared host
clock; measuring display scanout/photons still requires an external camera. `start`
accepts a protobuf JSON WebRTC offer; media and input use the encrypted peer
connection. Screen input uses its independent framing revision, with signed session
bindings and machine-wide control grants required for every controlling viewer.

Text, image and file clipboard sharing is available on Mac and Android viewers. Enable
**Share clipboard** in Screen options (Mac) or the bottom bar (Android). Mac
⌘C/⌘X and remote app menus copy back to the local clipboard; ⌘V transfers the
local content and then invokes the host paste shortcut. Android provides Copy and
Paste buttons, IME clipboard actions and the host's ⌘V hardware shortcut.
Synchronization runs only for the focused controlling viewer. View-only viewers
cannot read or write it. Connecting or taking control does not overwrite either
clipboard; subsequent supported changes sync in both directions. Clipboard access can
require an OS pasteboard grant; a denied request leaves video running.

UTF-8 plain text supports up to 1 MiB, including empty text, Unicode and newlines.
PNG, JPEG, TIFF and WebP images and up to 64 regular files support 8 MiB combined.
Folders, symbolic links, duplicate filenames and rich-text formatting are not
transferred. Binary clipboard support is negotiated from the host's capture capabilities.
A dedicated encrypted
WebRTC channel uses 16 KiB chunks and bounded buffering. Native clipboard IPC runs
in a separate instance of the installed helper, outside capture and heartbeat
queues. A stale control grant is rejected before a mutation. Clipboard shortcuts
wait for prior selection input, and subsequent typing waits for the shortcut
acknowledgment. Failed/uncertain
pastes are never automatically retried; the daemon retains the most recent 128
mutation results per session for duplicate detection. Reconnecting creates a new
session and never replays clipboard operations. Contents never enter Dieter history
or logs. Native file URLs use private staging under `DIETER_HOME/clipboard` (the
Android app uses its private files directory and granted content URIs). The next
file transfer removes batches older than 24 hours and retains at most eight batches
(64 MiB); disconnecting does not invalidate the most recently copied files.

The CLI uses the same daemon implementation over local, direct TLS or relay:

```sh
dieter screen clipboard enable SESSION
dieter screen clipboard read SESSION
dieter screen clipboard write SESSION --file clipboard.txt
dieter screen clipboard paste SESSION --file - < clipboard.txt
dieter screen clipboard paste SESSION --image screenshot.png
dieter screen clipboard paste SESSION --attach report.pdf --attach diagram.png
dieter screen clipboard copy SESSION
dieter screen clipboard read SESSION --output-dir ./received-files
dieter screen clipboard cut SESSION
dieter screen clipboard disable SESSION
```

`read` prints protobuf JSON, including `hasText`, `changed`, `revision`, `text` and
`items` (binary data is base64). `--output-dir` saves binary items into a new
directory without overwriting files and omits their data from the JSON output.
`write` only changes the host clipboard; `paste` also invokes its paste shortcut.
`copy` and `cut` invoke the host shortcut and return the resulting content after the
clipboard changes.
`write` and `paste` require exactly one of `--file` (UTF-8; `-` reads stdin),
`--image`, or repeatable `--attach`. All operations require
an existing controlling session; they do not silently take control. Clipboard
errors are surfaced separately; a broken clipboard channel reopens the screen
session without replaying the interrupted paste. Transient connection failures
retry while the screen tab stays open: 250 ms initially, capped at five seconds,
with no attempt limit. Mac wake and Android resume reopen the authenticated route.
Explicit Disconnect, closing the tab, and permanent permission/identity/policy
errors stop recovery. Mac inactivity disconnect is optional and disabled by
default; explicitly configured inactivity limits remain honored.

Native screen regression checks:

```sh
just mac screens-native-test
just mac screens-test
DIETER_TEST_SCREEN_QUALITY_SOAK_SECONDS=180 just mac screens-test
DIETER_TEST_SCREEN_CAPTURE_REAL=1 just mac screens-test
DIETER_SCREEN_TEST_SOURCE=screen just e2e run --suite screens
```

The first three use generated pixels and dry-run input; the 180-second run includes
45 seconds idle, intermittent updates and resumed motion. The last two require Screen
Recording and event-posting permission and send events only to an owned native
fixture window. All use random loopback listeners and disposable daemon data;
the installed daemon is untouched. Native Mac viewer integration refuses to start
while an operator Dieter Mac app is running. Android screen tests install the
separate `com.dbpprt.dieter.e2e` package on the selected emulator,
preserve the normal Android app, and refuse an already-running fixture package.
Evidence paths are printed by the test. Android screen runs require a macOS
capture host. Concurrent Mac companion execution in the new framework is disabled
until the Mac adapter is qualified; the old multi-client environment flag was removed.

Screen sharing supports up to four clients per machine. Matching display,
codec profile, and stream settings share a hardware encoder when decoded-reference
recovery is disabled. Recovery-enabled viewers use independent encoders so one
viewer cannot invalidate another viewer’s references. All renditions still use
one native capture stream per physical display, with at most four encoders.
Each viewer adapts independently and can change displays or disconnect without
closing another session. Only one client controls mouse and keyboard at a time.
The first control-capable client receives control; other clients use Take Control
(or `dieter screen control take SESSION`). Release Control leaves the video open.
Control handoff is part of the current contract; every viewer uses revocable grants.
`dieter screen sessions` reports connected clients and allocated capture resources.

### Screen codec selection

Native viewers start with H.264. Their video quality menu can select Automatic
or strict HEVC. HEVC uses hardware encoding/decoding, 8-bit 4:2:0 SDR Main,
up to 1920×1080 at 60 fps. `screen capabilities` exposes codec-specific modes.
Automatic selects HEVC only when both endpoints advertise a compatible mode;
codec initialization or first-frame decoding failure retries H.264 once per
connection. Transient reconnects retain that decision. Strict HEVC reports an
unsupported mode instead of silently changing codecs. Changing codecs creates a
fresh authenticated session and releases held input.

`dieter screen start --request offer.json --codec auto|h264|hevc` overrides the
protobuf JSON codec preference without rewriting SDP. The request must include
an offer supporting the requested codec. Omitting the flag preserves the JSON
preference (an absent field means automatic). CLI signaling supports the same
local, verified direct TLS, and authenticated relay routes. Existing H.264-only
clients and hosts remain compatible. HEVC remains opt-in pending matched-quality
bandwidth and physical-device latency benchmarks.

Screen congestion feedback also has a fast downward bitrate path. Fresh TWCC loss
or repeated queue growth can update the encoder at most every 100 ms, independently
of the slower cadence/resolution controller. Quiet traffic, stale feedback and
RTT changes alone do not trigger it. Shared viewers retain separate ceilings;
a bitrate-only change on an exclusive encoder preserves its reference frames.
Recovery waits at least two seconds after a fast cut and retains the normal
quality controller's measured recovery rules.

For isolated latency experiments, `DIETER_SCREEN_FAST_BITRATE=0` on the daemon
restores the slower adaptation path. On the Mac viewer,
`DIETER_SCREEN_PRESENTATION=display-link` selects display-timed rendering with
`CAMetalDisplayLink`; `immediate` is the default. Both modes render independently
of the UI thread and pause when idle. These are process-environment diagnostics,
not session RPC options. Restart only a disposable test process to compare them.

`DIETER_TEST_SCREEN_LATENCY_MATRIX=1 just mac screens-test` runs H.264/HEVC,
immediate/display-link, and fast adaptation off/on against an isolated native
fixture. Add `DIETER_TEST_SCREEN_CAPTURE_REAL=1` to measure owned-application
input to actual display presentation; that run requires native capture/input
permissions. Each run prints its evidence directory and writes JSON labeled with
the codec and both experiment settings. The runner refuses an existing Dieter
app and never manages the operator daemon. Network-drop coverage runs separately
in `TestFastBitrateReceivesRealTWCCOnConstrainedWebRTC` on an isolated virtual
network; synthetic and physical input measurements must not be compared as if
identical workloads.

### Screen reference recovery and adaptive FEC

Native Mac and Android viewers negotiate decoded-reference recovery for H.264
and HEVC. Supporting VideoToolbox encoders recover from an acknowledged long-term
reference after loss. Decoder completion, frame identity, display generation,
and the authenticated input epoch scope each acknowledgement. Unsupported
hardware, clients without the required codec capability, expired references, or an unacknowledged recovery use
the existing keyframe path. Each recovery viewer gets its own bounded encoder.

`dieter screen start --request offer.json --reference-recovery` opts an automation
receiver into this protocol. The offer must advertise the generic frame descriptor
RTP extension, and the receiver must acknowledge `reference` host events only
after successful decoding through `decodedReferences` in receiver feedback.
Omitting the flag preserves the request JSON; `--reference-recovery=false`
explicitly disables it. Signaling works over local, direct TLS, and relay routes.

FlexFEC-03 protection is negotiated automatically. Fresh moderate loss without
queue growth selects a 10% or 20% repair-byte allowance; stale feedback, sustained
clean traffic, excessive loss, or queue growth disables repair. Encoder bitrate
reserves this allowance within the existing bandwidth budget. Media never waits
for a parity group. Protection adds redundancy and cannot repair every loss burst.
`screen sessions` / `screen status SESSION` report `referenceRecovery`,
`referenceAcks`, `referenceRecoveryFrames`, `referenceRecoveries` (decoded),
`fecPercent`, `fecPackets`, and `fecBytes`.

For disposable-process A/B tests, `DIETER_SCREEN_LTR=0` disables reference recovery
and `DIETER_SCREEN_FEC=0` disables FEC negotiation. Do not restart an operator daemon
for these comparisons. `DIETER_TEST_SCREEN_RECOVERY=1 just mac screens-test`
runs the native H.264/HEVC recovery matrix. Android coverage uses
`just e2e run --case screens.screen-recovery-end-to-end-test`.
Both use authenticated disposable fixtures and targeted packet loss, without
altering saved credentials or system network configuration.

### Mac screen-share windows

The expand button in Screens undocks the selected live share into its own native
macOS full-screen window. The same media session, decoder, Metal surface, and
clipboard connection move with it. Other tabs and shares remain usable. Move the
pointer to the top of full screen to reveal the native toolbar, with screen
options, control handoff, **Return to Dieter**, and the full-screen toggle.
**Control–Command–F** enters/exits full screen from the viewer; ordinary Escape
continues to reach the remote application. Exiting full screen leaves a movable,
resizable window; closing that window returns the share to Dieter. Closing its
Screens tab disconnects and closes its separate window.

A controlling Mac viewer uses the local system pointer with the host's cursor
shape and hotspot. Pointer motion does not wait for video or network feedback,
and hovering over the video hides the delayed remote-position overlay even
before keyboard focus is acquired. View-only and explicitly embedded-cursor
sessions show the remote cursor and suppress the local pointer only inside the
video. Letterboxing, toolbar areas, and other windows keep the normal Mac cursor.
**Command–Shift–Escape** releases held input and pauses pointer forwarding until
the viewer is focused again. Window and application focus changes release held
keys and buttons.

`DIETER_TEST_SCREEN_UNDOCK=1 just mac screens-test` runs the authenticated,
isolated native full-screen journey, verifies session continuity and input,
and records docked/full-screen input-to-Metal timing and screenshots. It never
replaces or restarts the operator daemon.

### Screen performance qualification

`screen status SESSION` also reports actual decoder identity, optional hardware
and low-latency acceptance, encoder setting/fallback diagnostics, native damage
fraction and content classification. Absent optional booleans mean unknown.
Accepted codec configuration is not proof of a latency improvement.

`mediaRtpBytes`, `repairRtpBytes`, `probeRtpBytes` and `fecRtpBytes` count serialized
RTP headers, payload and padding after successful sending. They exclude
SRTP/RTCP/SCTP/ICE and IP/UDP/TURN overhead and must not be called total wire bytes.
`recoveryDiagnostics` exposes history hits/misses, cap evictions, expired repairs,
duplicate requests and retained packets/bytes. History is bounded to 4,096 packets
and 4 MiB per session across SSRCs, with 250 ms maximum useful retention.
Generation changes retire old repair history and queued repairs recheck deadlines.

New experiments preserve compatibility defaults: `DIETER_SCREEN_PRESENTATION=bounded`
limits compositor submissions; `low-latency` tests unsynchronized presentation.
`DIETER_SCREEN_CONTENT_ADAPTATION=1` enables the damage/cost controller;
`DIETER_SCREEN_ENCODER_BURST_MS=100|250|500` tests shorter encoder caps with 1.5×
headroom; `DIETER_SCREEN_OVERLAP=1` admits at most one extra fresh encode behind
a send when both helper and daemon support it. These are disposable-process
experiments, not reasons to restart an operator daemon.
Android low-latency configuration, SurfaceView/EGL, and direct MediaCodec output
remain fixture switches until physical performance qualification. Use
`DIETER_SCREEN_TEST_DIRECT_SURFACE=1` with the isolated Android runner for real
decoder output to an owned SurfaceView; `DIETER_SCREEN_TEST_SURFACE=1` selects
the separate EGL experiment. The direct path reports Android frame-render
callbacks, which may be batched and are not physical scanout timestamps.
The reproducible [SDK extension](../native/android-webrtc/README.md) preserves all
four pinned JNI binaries and uses real dequeued output buffers.

Run repeatable physical/local qualification with:

```sh
python3 scripts/qualify_screens.py --manifest docs/screenshare-qualification-local.json \
  --output /tmp/dieter-screen-qualification-UNIQUE --serial EXACT_PHYSICAL_SERIAL
```

The runner records source identity, exact settings, hardware, results and bounded
evidence. `--baseline /path/to/results.json` compares matching latency/cadence
cases. Missing mandatory cases fail; an external-device or optical case is
reported unavailable. The physical Android fixture uses its own app ID and never
replaces the operator app. See [decoder adapter contract](../apps/android/webrtc-adapter.md)
and [implementation evidence](screenshare-performance-implementation-2026-09-18.md).
