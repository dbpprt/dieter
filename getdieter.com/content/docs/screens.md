---
title: "Screens (remote desktop)"
linkTitle: "Screens"
description: "View and control an enrolled machine over peer-to-peer WebRTC with hardware H.264 — media never touches the gateway."
group: "Guides"
weight: 14
slug: "screens"
---

Screens gives you a view-and-control experience of an enrolled machine's
display. Media and remote input travel **directly** between your client and the
daemon; the gateway only brokers bounded signaling.

## Capture on macOS

On macOS, Screens uses the packaged `dieter-capture` helper with
ScreenCaptureKit and VideoToolbox hardware H.264. The helper keeps at most one
pending frame, scales the stream to the viewer's requested bounds, and accepts
live keyframe and bitrate feedback from WebRTC. It captures the primary display
by default after guided `dieter setup` verifies Screen Recording access for the
exact signed helper installed beside the daemon.

```sh
dieter daemon permissions        # reopen the permission guide
dieter daemon permissions --check
```

## Selecting a source

| Variable | Effect |
| --- | --- |
| `DIETER_REMOTE_DESKTOP_HELPER` | Select another signed native helper. |
| `DIETER_REMOTE_DESKTOP_DISPLAY` | Select another capture source (display). |
| `DIETER_REMOTE_DESKTOP_FFMPEG` | Non-macOS experimental hosts (FFmpeg/libvpx). |
| `DIETER_REMOTE_DESKTOP_SOURCE=synthetic` | Reserved for isolated transport diagnostics. |

## Transport and admission

The daemon hosts an H.264 peer with Pion. Media and bounded remote input travel
directly over ICE/DTLS/SRTP or through a separately configured TURN server,
never through the Dieter gateway.

The Mac verifies an Ed25519 binding between the offer, daemon DTLS fingerprint,
session, nonce, lease, control grant, display, and input epoch before applying
the answer. Pointer motion uses an unordered no-retransmit DataChannel while
keys, buttons, scrolling, and release-all use a reliable channel. The signed
native helper owns macOS capture and event-posting permissions and releases
every held input immediately on disconnect.

{{< callout type="note" title="Capture is lazy" >}}
Screen capture starts only after WebRTC connects and stops when its renewable
lease expires. One explicitly enabled viewer/controller is allowed per daemon.
{{< /callout >}}

## Lifecycle

Capture is lazy and runs only while an admitted WebRTC session is connected. A
clean viewer close stops it immediately; an ungraceful signaling or WebRTC
disconnect gets a five-second reconnect grace, after which the daemon cancels
and reaps the complete capture process group.

## TURN configuration

If your peers cannot reach each other directly, configure TURN on the gateway
with `DIETER_RTC_TURN_URLS` and a shared `DIETER_RTC_TURN_SECRET`. The gateway
derives ephemeral, time-limited credentials—see **[Run a gateway](/docs/gateway/)**.
