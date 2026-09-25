> **Historical engineering record.** This dated investigation or implementation

> Historical record: Android launcher scripts and test aliases referenced below
> have been retired. Use the [current native test guide](../tests/e2e/README.md)
> for supported commands and selectors.
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Screen-sharing latency implementation — 17 September 2026

Dieter keeps its authenticated WebRTC media path, native ScreenCaptureKit / VideoToolbox host, and native clients. This change reduces avoidable receiver/input waits, adds high refresh configuration, and gives the isolated fixture a pixel-verified input latency benchmark.

## Behavior

- Mac video now reaches Metal directly from the hardware decoder callback. The normal libwebrtc callback remains active for reference management and statistics; a passive track sink avoids presenting the same frame again at libwebrtc's later scheduled time. Each decoder sink captures a renderer generation, preventing late callbacks after reset/reconnect from displaying an old session.
- Metal obtains an available drawable before choosing the newest decoded frame. If the compositor holds a drawable, newly decoded frames can replace the pending surface during that wait. The existing one-submission/one-pending-frame limit remains intact. Display synchronization remains enabled.
- Both native viewers send the first pointer movement synchronously. A burst retains only its latest position and flushes after the remaining part of a four-millisecond interval. Reliable input clears obsolete pending motion; focus loss/disconnect cancels it. Reliable key/button release and ordering barriers remain in place.
- Native capability discovery advertises a 120 fps ceiling. Mac and Android screen options expose 30/60/90/120 fps when the host advertises them, retaining a 60 fps default and compatibility with older hosts. The existing CLI configure operation accepts 1–120 fps through local, direct TLS and gateway relay routes. Above 60 fps, normalized geometry is capped at 1920×1080 to remain within H.264 level 5.2; 4K60 remains available. Capture cadence, encoder and decoder capacity, and the physical display still determine actual throughput.
- Motion policy reduces pixels before cadence when sustained congestion is present and the stream is above the 640-pixel floor. It still honors computation limits and uses a four-second resize cooldown. Automatic/detail policies retain cadence-first behavior. Recovery requires fresh evidence and proceeds gradually.
- Packet retransmission now uses a per-frame repair deadline starting at its first packet, rather than extending useful life when the last packet is finally sent. With fresh RTT evidence, the window is `clamp(2 × RTT + 2 frame intervals, 50 ms, 250 ms)` and reserves half an RTT for outward transit. Stale/missing timing retains the previous bounded retention policy. Expired repair requests request a keyframe with the existing refresh rate limit. This is a recovery deadline, not an imposed playback buffer.
- A native helper shutdown racing a frame-credit command now retains the recoverable helper-stopped classification. Either completion order can therefore trigger the same bounded client recovery.

No new RPC or wire field is needed: existing stream configuration, capability and timing fields carry these changes. Encoder credits remain at one; the measurements did not justify introducing another encoded-frame queue. FEC and a custom transport are not enabled by this change. A future FEC experiment must negotiate a format understood by both native receivers, include parity in congestion accounting, and compare decoded output under loss against the existing repair path.

## Measurement and reproduction

Run the repository checks with:

```sh
just check-changed --dry-run
just check-changed
```

Focused checks:

```sh
just mac screens-native-test
just mac screens-test
DIETER_TEST_SCREEN_FPS=120 just mac screens-test
DIETER_TEST_SCREEN_CAPTURE_REAL=1 just mac screens-test
just android screens-test
```

The scripts build disposable signed helpers and fixtures under temporary roots, use ephemeral identities and loopback ports, and leave the operator daemon alone. The real-screen test sends input only to its owned AppKit window. The Android script pins emulator-5554 and removes its temporary fixture-only ADB reverse mapping.

The Mac test writes `latency.json` in the evidence directory printed as `Native screen evidence`. It includes capture-to-actual-Metal-presentation median/p95, idle resumes, and input-to-presentation median/p95. Capture timing uses modular RTP timestamps derived from the **same machine's monotonic clock**. Do not subtract these timestamps on unrelated machines.

Input measurement starts immediately before dispatch, then checks luminance in the decoded frame at actual drawable presentation. Synthetic mode changes a reserved patch only after the authenticated input reaches the helper. Real-screen mode changes the owned application's background in response to actual key events, then observes those pixels through ScreenCaptureKit, hardware encoding, WebRTC, decoding and Metal. The test's polling interval affects when the next sample starts, not the measured end timestamp. Real-screen runs write `input-latency.json` separately.

These are software presentation measurements, not an optical measurement of display scanout. The synthetic path excludes application rendering and ScreenCaptureKit capture. The real path includes those stages, but a camera or photodiode is still needed to measure physical input-to-photon latency. Two-machine wired/Wi-Fi/WAN/TURN results require those machines and routes; loopback and emulator results do not establish them.

## Validation results

On the local Apple M4, the native synthetic 1920×1080 stream sustained **119.9 fps** with **6.04 ms mean hardware encode time** (30 warmup frames, 240 measured frames). This measures the host encoder; it does not imply that a 60 Hz client display presents 120 distinct frames per second.

The default 60 fps Mac fixture measured:

| Measurement | Before | Updated |
| --- | ---: | ---: |
| Capture → actual Metal presentation, median | 53.19 ms | 43.34 ms |
| Capture → actual Metal presentation, p95 | 65.64 ms | 60.19 ms |
| Synthetic input → actual Metal presentation, median | Not measured | 63.16 ms |
| Synthetic input → actual Metal presentation, p95 | Not measured | 77.80 ms |

The updated capture result uses 1,730 presentations; input uses 24 alternating, pixel-verified responses. These are representative runs on this workstation, with background load differing between runs, rather than a controlled performance guarantee. Input acknowledgement time is deliberately not substituted for visible response time.

Validation so far includes affected Go packages and their reverse dependencies under the race detector, `go vet`, native hardware/input/backpressure tests, all 610 Mac unit tests, Android unit tests, and the isolated Mac and Android screen-sharing journeys. The screen journeys cover authenticated connection, hardware video, pointer/key input, clipboard, live 120→60 fps configuration, session expiry, helper shutdown/recovery, and teardown. CLI configuration is covered on loopback, verified direct TLS, and authenticated relay routes.

The Android emulator journey rendered 1920×1080 at 59.76 fps; reported encode time was 6.02 ms. Android's render-stage counter measures EGL submission, so it is not comparable to the Mac actual-presentation measurement.

The broad checks are **not all green**. `just check-changed` stopped in the Mac conversation smoke suite: `content-code-line-link` did not reveal the requested line, and `content-terminal-input` did not observe terminal output. Running the remaining smoke suites separately also found sidebar hover/label-layout failures (`project-actions-on-hover`, `project-name-before-host`). These paths are outside the modified screen-sharing code; they have not been established as pre-existing by a clean-base rerun.

The full Android connected suite reported five failures: three real-gateway operations returned `UNAUTHENTICATED`, background live sync timed out, and the settings test expected a saved local endpoint but read the gateway endpoint. Tests requiring separate fixtures were skipped. The isolated screen-sharing fixture passed independently; the broad connected suite does not establish real-gateway readiness on this emulator.

The 120 fps requested Mac receiver run passed all 11 focused tests. This workstation's 60 Hz display presented **59.99 fps**; the adaptive host settled from a 120 fps ceiling to 90 fps during the run. Capture-to-presentation measured **65.18 ms median / 67.44 ms p95**, and synthetic input response **80.18 ms median / 81.02 ms p95**. Thus, the higher ceiling did **not** improve latency on this display. High refresh is opt-in; use a capable display and measure the complete path before choosing it.

Mac core, board, machine, terminal, island, and workspace smoke suites passed. Conversation and sidebar failures are listed above. The owned Android emulator was gracefully stopped after testing; no operator daemon was replaced or restarted.

The real desktop run passed all 11 focused tests. Across 24 pixel-verified responses in the owned AppKit application, actual input-to-Metal-presentation measured **61.09 ms median / 68.57 ms p95**. This includes application response, ScreenCaptureKit, hardware H.264, WebRTC, native decoding and presentation. It also verified actual keyboard, pointer, Unicode/scroll, held-key release, clipboard, and display switching. These results establish the local implementation, not Sunshine/Moonlight/Parsec performance parity on a remote network.

Local evidence from this run (temporary paths):

- Default 60 fps timing: `/var/folders/nk/8324zqs10fq249x2ythzxc540000gn/T/dieter-screen-viewer-E7501AC7-D803-47BF-B0E6-CBBFEB86796F/latency.json`
- Requested 120 fps timing: `/var/folders/nk/8324zqs10fq249x2ythzxc540000gn/T/dieter-screen-viewer-2D28B80F-0063-46A6-91F4-9D915C168D2F/latency.json`
- Real application response: `/var/folders/nk/8324zqs10fq249x2ythzxc540000gn/T/dieter-screen-viewer-73D3DC68-D5B1-432B-9C8A-E89445AD0C97/input-latency.json`
- Android screen journey and screenshots: `/tmp/dieter-android-screens.Gtvmdf/`
- Hardware throughput: `/tmp/dieter-latency-hardware.log`
- Broad checks: `/tmp/dieter-latency-check-changed.log`, `/tmp/dieter-latency-mac-remaining.log`, `/tmp/dieter-latency-android-connected.log`

Final lifecycle checks found no remaining test viewer, input target, capture fixture, or owned emulator process. The attached physical Android phone was not used.
