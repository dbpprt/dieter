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
through TURN. The gateway only brokers bounded signaling.

Agents and terminals can run headless. Screen hosting additionally needs an active
graphical session and the platform's capture and control permissions.

{{< screenshot src="macos-screens.png" width="1380" height="870" alt="Native Mac screen-sharing viewer streaming an Orbit sample dashboard from Studio Mac" caption="Live screen sharing through the native viewer. The documentation fixture captures only its owned demo window; the shipped host shares a display." >}}

## Open a screen

Choose **Screens**, select an enrolled machine, and choose a display and quality.
The first control-capable viewer receives control. Use **Take Control** to request
handoff from another viewer, or **Release Control** to keep watching without input.
Up to four viewers can connect; only one controls the machine at a time.

On Mac, the expand action moves the same session into a separate native window.
**Control–Command–F** toggles full screen. Closing that window returns the share
to Dieter; closing the Screens tab disconnects it. **Command–Shift–Escape**
releases held input and pauses pointer forwarding until you focus the viewer again.
Inactivity disconnect is optional and disabled by default.

On Android, one finger moves the remote cursor relatively; tap to click,
double-tap to double-click, and hold then move to drag. Two fingers zoom/pan the
local canvas; three fingers scroll the remote screen. The toolbar provides text
input, modifiers, special keys, right-click, and Fit screen. Leaving Screens or
backgrounding the app closes that session.

## Share clipboard

Enable **Share clipboard** in the Mac screen options or Android bottom bar. Only
the focused controlling viewer can read or write it. Connecting or taking control
does not immediately overwrite either clipboard. Supported changes then synchronize.

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
actionable degraded reason. See the **[Linux host guide](https://github.com/dbpprt/dieter/blob/main/docs/linux-support.md)**
for distro packages, systemd graphical-session behavior, and current feature
limits.

## Selecting a source

| Variable | Effect |
| --- | --- |
| `DIETER_REMOTE_DESKTOP_HELPER` | Select another native helper for development or isolated diagnostics. |
| `DIETER_REMOTE_DESKTOP_DISPLAY` | Select another capture source (display). |
| `DIETER_REMOTE_DESKTOP_SOURCE=synthetic` | Reserved for isolated transport diagnostics. |

Wayland portal sources can be represented as a locally approved selection
rather than a passively enumerable monitor. A viewer shows “waiting for approval
on Linux host” while that bounded local prompt is open.

## Transport and admission

The daemon hosts an H.264 or HEVC peer with Pion. Media and bounded remote input travel
directly over ICE/DTLS/SRTP or through a separately configured TURN server,
never through the Dieter gateway.

Native clients verify an Ed25519 binding between the offer, daemon DTLS fingerprint,
session, nonce, lease, control grant, display, and input epoch before applying
the answer. Pointer motion uses an unordered no-retransmit DataChannel while
keys, buttons, scrolling, and release-all use a reliable channel. The signed
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
disconnect gets a five-second reconnect grace, after which the daemon cancels
and reaps the complete capture process group.

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

For protocol fields, recovery/FEC details, clipboard commands, and qualification
workloads, see the [screen engineering reference](https://github.com/dbpprt/dieter/blob/main/docs/screen-sharing.md).
