---
title: "Screens (remote desktop)"
linkTitle: "Screens"
description: "View and control an enrolled macOS or Linux machine over peer-to-peer WebRTC. Media never touches the gateway."
group: "Workflows"
weight: 23
slug: "screens"
---

Screens gives you a view-and-control experience of an enrolled machine's
display. Media and remote input travel between your client and the daemon, directly or
through TURN. Signaling runs inside the end-to-end encrypted connection to the
machine, so the gateway can relay it but cannot read it.

Agents and terminals can run headless. Screen hosting additionally needs an active
graphical session and the platform's capture and control permissions.

{{< screenshot src="macos-screens.png" width="1380" height="870" alt="Native Mac screen-sharing viewer streaming an Orbit sample dashboard from Studio Mac" caption="Live screen sharing through the native viewer, captured in September 2026 with the earlier Mac design. That capture limited its source to an owned demo window; the shipped host shares a display." >}}

## Open a screen

Choose **Screens** on the Mac, or on Android and iOS open the machine from
**More** and choose **Screen** (Android's More sheet also has a screen button on
each machine). Then choose a display and quality.
The first control-capable viewer receives control. Use **Take Control** to request
handoff from another viewer, or **Release Control** to keep watching without input.
Up to four viewers can connect; only one controls the machine at a time.

On Mac, the expand action moves the same session into a separate native window.
**⌃⌘F** toggles full screen. Closing that window returns the share
to Dieter; closing the Screens tab disconnects it. **⌘⇧Esc**
releases held input and pauses pointer forwarding until you focus the viewer again.
Inactivity disconnect is optional and disabled by default.

On Android, iPhone, and iPad, one finger moves the remote cursor relatively;
tap to click, double-tap to double-click, and hold then move to drag. Two
fingers zoom/pan the local canvas; three fingers scroll the remote screen. The
toolbar provides zoom, Fit screen, the keyboard, and a right click at the
cursor; the screen menu holds refresh, display, quality, codec, and control.
Leaving Screens closes that session.

## Share clipboard

Enable **Share clipboard** in the Mac screen options or the Android and iOS
screen menu. Only the focused controlling viewer can read or write it. Connecting
or taking control does not immediately overwrite either clipboard. Supported
changes then synchronize.

Text supports up to 1 MiB. Supported images and up to 64 regular files have an
8 MiB combined limit. Folders, symlinks, duplicate filenames, and rich-text
formatting are not transferred. Binary support is negotiated with the host;
check capabilities rather than assuming every platform provides it.

Clipboard contents do not enter conversation history or logs. A reconnect or
uncertain result never automatically replays a paste. CLI operations require an
existing controlling session:

```sh
dieter screen clipboard enable SESSION_ID
dieter screen clipboard read SESSION_ID
dieter screen clipboard paste SESSION_ID --file clipboard.txt
dieter screen clipboard disable SESSION_ID
```

## Capture on macOS

On macOS, Screens uses the packaged `dieter-capture` helper with
ScreenCaptureKit and VideoToolbox hardware H.264 or opt-in HEVC. The helper keeps at most one
pending frame, scales the stream to the viewer's requested bounds, and accepts
live keyframe and bitrate feedback from WebRTC. It captures the primary display
when an authenticated session starts, after guided `dieter setup` verifies Screen
Recording and Accessibility access in the running daemon’s context. Grant the
daemon executable path shown by the guide. Screen sharing has no enable switch: it
is ready, needs OS permission, or is unsupported. The Mac app separately guides
required Accessibility and Screen Recording grants for Dieter.app.

The macOS daemon wakes the display before native capture starts and keeps it
awake until the capture process exits. It does not unlock the Mac or change
sleep or security preferences.

```sh
dieter daemon permissions        # reopen the permission guide
dieter daemon permissions --check
```

## Capture on Linux

Linux releases ship a matching unprivileged `dieter-capture` helper. X11 uses
GStreamer XImage/XDamage capture, XRandR monitor geometry, and XTest input.
Wayland uses the desktop's ScreenCast/RemoteDesktop portals and PipeWire; source
selection and control consent therefore appear locally on the host. The helper
prefers qualified VA-API, NVENC, or V4L2 H.264 and falls back to bounded x264 or
OpenH264 when installed. Raw desktop pixels remain in the helper.

An active graphical login, the distro's GStreamer plugins, and the appropriate
portal backend are required. A headless Linux daemon remains fully usable for
agents, terminals, and remote execution while screen hosting reports an
actionable degraded reason. See [Installation](/docs/installation/#linux) for
Linux service setup.

## Selecting a source

| Variable                                 | Effect                                                                |
| ---------------------------------------- | --------------------------------------------------------------------- |
| `DIETER_REMOTE_DESKTOP_HELPER`           | Select another native helper for development or isolated diagnostics. |
| `DIETER_REMOTE_DESKTOP_DISPLAY`          | Select another capture source (display).                              |
| `DIETER_REMOTE_DESKTOP_SOURCE=synthetic` | Reserved for isolated transport diagnostics.                          |

Wayland portal sources can be represented as a locally approved selection
rather than a passively enumerable monitor. A viewer shows “waiting for approval
on Linux host” while that bounded local prompt is open.

## Transport and admission

The daemon hosts an H.264 or HEVC peer with Pion. Media and bounded remote input travel
directly over ICE/DTLS/SRTP or through a separately configured TURN server,
never through the Dieter gateway.

Native clients verify an Ed25519 binding between the offer, daemon DTLS fingerprint,
session, nonce, lease, control grant, display, and input epoch before applying
the answer. They check it with the machine's key from your account's
[trusted devices](/docs/security/#trusted-devices), never with a key the gateway
supplies, and a renegotiated answer carries a binding of its own. Pointer
motion uses an unordered no-retransmit DataChannel while keys, buttons,
scrolling, and release-all use a reliable channel. The signed
macOS helper or release-verified Linux helper owns platform capture and input
permission and releases every held input immediately on disconnect.

{{< callout type="note" title="Capture is lazy" >}}
Screen capture starts only after WebRTC connects and stops when its renewable
lease expires. Up to four viewers can connect to one daemon, sharing capture
per display. Compatible streams share an encoder; reference-recovery streams
use independent encoders. One viewer controls input at a time, with explicit
Take Control and Release Control actions.
{{< /callout >}}

## Lifecycle

Capture is lazy and runs only while an admitted WebRTC session is connected. A
clean viewer close stops it immediately; an ungraceful signaling or WebRTC
disconnect gets a twenty-second reconnect grace, after which the daemon cancels
and reaps the complete capture process group. The renewable session lease lasts
thirty seconds; receiver feedback renews it only while signaling is authorized.

Android, macOS, and iOS preserve the existing peer for up to fifteen seconds
of temporary disconnection. Signaling reacquires an authenticated control route,
verifies the pinned machine identity, and resubscribes with the same session
nonce and offer. Delays are capped at five seconds, with up to fifteen seconds
without a received signal. Permanent authorization or identity failures stop
recovery.

When the peer returns, the client requests a fresh frame. While the view is
focused, a video stall also requests a fresh frame after ten seconds without a
new presentation (three seconds when starting); only another twenty seconds
without a frame triggers session replacement. Refresh probes preserve the
adapted bitrate; configuration timeouts retry without discarding healthy video.
A quiet desktop may receive a refresh probe without being disconnected. Failed
peers are replaced with the existing bounded backoff.

## Experimental virtual displays (macOS)

A Mac host started with `DIETER_SCREEN_VIRTUAL_DISPLAY=1` offers an
experimental **Virtual display** screen option on Mac, iOS and Android. The
virtual desktop uses the viewer's drawable pixels within codec limits (H.264 up
to 3840×2160 at 60 fps, HEVC up to 1920×1080), with independent 1×/2× UI
scaling. The controlling session holds the display lease; changes restore when
the session closes, control moves to another viewer, or something fails.

```sh
dieter screen virtual status SESSION
dieter screen virtual set SESSION --width 2560 --height 1440 --scale 2
dieter screen virtual restore SESSION
```

Disabling the physical display while a virtual one is shown is a separate,
hardware-qualified opt-in (`DIETER_SCREEN_VIRTUAL_DISABLE=1`): it requires an
identified physical main display and waits for a presented frame. A helper with
its own watchdog and a recovery journal under `DIETER_HOME/virtual-display`
restores physical output first. See `dieter screen virtual --help` and the
[CLI skill](https://github.com/dbpprt/dieter/blob/main/.agents/skills/dieter-cli/SKILL.md#experimental-macos-virtual-desktop)
for limits and recovery semantics.

## TURN configuration

If your peers cannot reach each other directly, configure TURN on the gateway
with `DIETER_RTC_TURN_URLS` and a shared `DIETER_RTC_TURN_SECRET`. The gateway
derives ephemeral, time-limited credentials. See **[Run a gateway](/docs/gateway/)**.

## Quality and diagnostics

H.264 is the compatibility default. HEVC is opt-in, hardware encoded and decoded,
SDR Main 4:2:0, up to 1080p60. Automatic codec selection retains a bounded H.264
fallback when HEVC initialization or first-frame decoding fails. H.264 supports
up to 4K60 or 1080p120 when both endpoints and the network sustain it.
Linux hosts currently advertise H.264 only; hardware ceilings and software
fallbacks are capability-detected, and Linux HEVC is intentionally unavailable.

Use `dieter screen status SESSION` to inspect actual stream size/rate, decoder
identity, encoder configuration, timing endpoint and bounded recovery counters.
Mac presentation and Android EGL submission are different measurements; neither
is an optical input-to-photon measurement. RTP traffic counters exclude
transport/control overhead. Quality settings and bitrate are adaptive ceilings.
No matched Parsec or Moonlight performance claim is implied by codec support.

For protocol fields, see the
[API schema](https://github.com/dbpprt/dieter/blob/main/api/proto/dieter/v1/screens.proto).
Hardware qualification suites are described in the
[testing guide](https://github.com/dbpprt/dieter/blob/main/docs/testing.md#layers).
