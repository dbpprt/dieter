# Experiment 1: Pion WebRTC screen sharing

This is the first end-to-end vertical slice from [`../../plan.md`](../../plan.md).
It deliberately lives in a nested Go module so its experimental dependencies do
not enter the Dieter daemon or product clients.

The slice proves:

- real desktop capture through FFmpeg on macOS, Windows, and Linux/X11;
- live VP8 on a WebRTC video track rather than screenshots over HTTP;
- a browser viewer with connection, route, codec, resolution, bitrate, loss,
  first-frame, and host capture diagnostics;
- direct ICE with loopback/LAN candidates and optional STUN/TURN servers;
- a reliable WebRTC data channel with a continuous RTT probe;
- bearer-protected signaling and one active capture session;
- bounded signaling input, ICE-gathering timeout, and session lease;
- an automated Pion-to-Pion test that receives RTP and a data-channel reply.

It is a bake-off artifact, not product code. In particular, signaling is one
HTTP offer/answer exchange with non-trickle ICE; production signaling belongs
in Dieter's authenticated daemon RPC, with trickled candidates and a signed
DTLS-fingerprint binding.

## Requirements

- Go 1.26.5 or newer;
- FFmpeg with `libvpx` for real screen capture;
- a current WebRTC-capable browser;
- macOS Screen Recording permission when capturing macOS.

The `synthetic` source requires no FFmpeg and is useful for transport and UI
checks.

## Run locally

```sh
cd experiments/1-webrtc-e2e
go run . -source synthetic
```

Open the exact tokenized URL printed by the process and choose **Connect**.
The token is placed in the URL fragment, so the browser does not send it in an
HTTP request or referrer.

For the real primary macOS display:

```sh
go run . -source screen -display 0 -fps 30 -bitrate-kbps 4000
```

List the AVFoundation screen indices when needed:

```sh
ffmpeg -hide_banner -f avfoundation -list_devices true -i ""
```

macOS may terminate the first capture while it presents Screen Recording
permission. Grant the permission to the terminal/host executable, restart the
experiment, and reconnect. If capture cannot start, the session reports a
bounded startup error instead of waiting indefinitely for FFmpeg.

Linux/X11 defaults to `$DISPLAY`; `-display :1.0` overrides it. Windows defaults
to FFmpeg's `desktop` gdigrab source. Automated Wayland portal/PipeWire capture
is intentionally deferred to the production-host bake-off described in the
plan.

## Exercise two machines

Start the experiment on the remote machine but keep signaling bound to
loopback:

```sh
go run . -source screen -listen 127.0.0.1:8787
```

From the viewer Mac, forward signaling:

```sh
ssh -L 8787:127.0.0.1:8787 remote-machine
```

Open the printed URL on the viewer Mac, keeping the token fragment. The HTTP
offer/answer goes through SSH, while WebRTC still selects an ICE path between
the peers. Add a STUN server if the peers are on different routed networks:

```sh
go run . -source screen \
  -stun stun:stun.example.com:3478
```

Force realistic relay coverage with short-lived test credentials:

```sh
go run . -source screen \
  -stun stun:turn.example.com:3478 \
  -turn 'turn:turn.example.com:3478?transport=udp,turns:turn.example.com:443?transport=tcp' \
  -turn-username "$TURN_USERNAME" \
  -turn-password "$TURN_PASSWORD"
```

Supplying TURN candidates does not force relay selection. ICE still prefers a
higher-priority direct candidate pair when one works.

## Verify

```sh
go test ./...
go test -race ./...
go build ./...
```

The end-to-end test creates two real Pion peer connections, exchanges SDP via
the HTTP signaling handler, establishes ICE/DTLS/SRTP/SCTP, receives video RTP,
receives the `probe` data-channel reply, and verifies host frame counters.

## Safety and limitations

- The default listener is loopback. Binding to `0.0.0.0` exposes plain-HTTP
  signaling and is suitable only on a trusted disposable network. Prefer SSH
  forwarding.

- The token protects experiment endpoints but is not a substitute for
  Dieter's daemon identity and account authentication.

- A new offer closes the previous capture session. Capture also stops when the
  session lease expires, the peer fails, the viewer calls `/close`, or the
  process exits.

- The experiment does not inject keyboard or pointer events.

- FFmpeg/libvpx is a convenient experiment source. It is not a decision to
  bundle a Homebrew or GPL-enabled FFmpeg build in the product.

- Non-trickle ICE intentionally keeps the experiment small but adds connection
  setup latency. Product signaling will trickle bounded candidates.

- The synthetic source repeats one valid VP8 keyframe. It validates the media
  path but is not a capture or quality benchmark.
