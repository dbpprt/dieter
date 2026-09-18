---
title: "Screens (remote desktop)"
linkTitle: "Screens"
description: "View and control an enrolled machine over peer-to-peer WebRTC with hardware H.264 or opt-in HEVC. Media never touches the gateway."
group: "Guides"
weight: 14
slug: "screens"
---

Screens gives you a view-and-control experience of an enrolled machine's
display. Media and remote input travel **directly** between your client and the
daemon; the gateway only brokers bounded signaling.

## Capture on macOS

On macOS, Screens uses the packaged `dieter-capture` helper with
ScreenCaptureKit and VideoToolbox hardware H.264 or opt-in HEVC. The helper keeps at most one
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
| `DIETER_REMOTE_DESKTOP_SOURCE=synthetic` | Reserved for isolated transport diagnostics. |

Linux daemons are headless hosts and do not advertise screen displays or
codecs. The Mac and Android clients keep them visible for machine context but
disable starting a screen session with the daemon-provided reason.

## Transport and admission

The daemon hosts an H.264 or HEVC peer with Pion. Media and bounded remote input travel
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

Use `dieter screen status SESSION` to inspect actual stream size/rate, decoder
identity, encoder configuration, timing endpoint and bounded recovery counters.
Mac presentation and Android EGL submission are different measurements; neither
is an optical input-to-photon measurement. RTP traffic counters exclude
transport/control overhead. Quality settings and bitrate are adaptive ceilings.
No matched Parsec or Moonlight performance claim is implied by codec support.
