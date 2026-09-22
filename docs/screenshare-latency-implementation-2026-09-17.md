> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Screen bitrate response and Mac presentation scheduling

Implemented options 3 and 2 on the existing hardware/WebRTC path. No session RPC,
CLI operation, authentication rule, media codec default or gateway data ownership
changes are required. Android benefits from the host bitrate controller; this
change does not replace Android's EGL renderer.

## Host bitrate response

- RTCP/TWCC and GCC publish a single coalesced wakeup. They never call the native
  helper, block on encoder configuration, or create a task per packet.
- The session's existing serialized adaptation worker evaluates this lane at
  most every 100 ms. It uses fresh feedback about recent sent packets, a minimum
  packet count/measurement span, loss or two queue-growth observations separated
  by at least 100 ms. One delayed burst, stale GCC estimates, quiet traffic, RTT
  changes and repeated acknowledgements cannot repeatedly reduce quality.
- Congested delivery can reduce the encoder budget immediately to 85% of the
  observed delivery rate, bounded by the requested ceiling and 100 kbps floor.
  Loss without a throughput measurement makes a bounded 15% reduction; a fresh
  lower GCC target can reduce it further.
- Native configuration has a one-second deadline, checks the user configuration
  revision, commits only on success, and runs independently of feedback reading.
  Logs distinguish feedback age from native configuration acknowledgement time.
- An exclusively owned encoder changes VideoToolbox's rate properties in place,
  retaining references, capture cadence and display generation. A shared viewer
  splits into its own bounded rendition when necessary, preserving other viewers'
  ceilings; that split can require a new encoder and initial keyframe.
- A two-second recovery hold prevents the slow controller from immediately
  undoing a cut. Cadence, dimensions and upward recovery retain their existing
  measured/hysteretic control path.

`DIETER_SCREEN_FAST_BITRATE=0` disables this lane for an isolated daemon A/B run.
The normal default enables it.

## Mac rendering

AppKit owns window layout and input coordinates. A private render run loop owns
Metal encoding, drawable waits, display-link callbacks and GPU completion. It
retains one GPU submission and one replaceable decoded frame. Decode callbacks
carry generation tokens; reset/close rejects old frames and late GPU callbacks.

Hardware presentation timestamps and counters update independently of MainActor.
UI notifications coalesce to one scheduled update containing the newest frame.
NV12/BGRA surfaces remain on the GPU; the CPU I420 conversion path is not used.
Resize/backing-scale updates are serialized with rendering. Display-link callbacks pause after a 100 ms idle grace (avoiding a restart between
normal video frames), and renderer teardown stops its private run loop.

`DIETER_SCREEN_PRESENTATION=immediate` is the default. The alternative
`display-link` uses `CAMetalDisplayLink` with preferred frame latency 1 and selects
the newest decoded frame when the display callback supplies a drawable. It
commits commands and calls the drawable's untimed `present()` method, as required
by [Apple's callback documentation](https://developer.apple.com/documentation/quartzcore/cametaldisplaylinkdelegate/metaldisplaylink(_:needsupdate:)).
The estimated target presentation timestamp is used for diagnostics, not as an
argument to timed presentation, which Apple prohibits for display-link drawables.

## Verification and interpretation

The network regression exercises real encrypted WebRTC/TWCC over Pion's isolated
virtual network. It drops media under a bandwidth constraint, checks that fresh
feedback reaches encoder configuration within 200 ms, and verifies reliable
control messages remain responsive. Native tests separately exercise that
production configuration path against hardware H.264 and HEVC: a 12000 -> 2550
kbps cut is followed by 30 frames with unchanged generation and no forced IDR.
The native test bounds feedback-to-configuration acknowledgement to 250 ms.

Focused Swift tests cover latest-frame replacement, reset during GPU ownership,
released decoders, bounded UI notifications and rendering work continuing while
MainActor is blocked. The GUI fixture also checks actual Metal presentation
continues through a deliberately blocked UI thread, idle pauses, native NV12,
resize/reset handling and input-induced pixel changes.

An initial display-link HEVC run exposed a 39 fps cadence regression caused by
pausing between frames. The 100 ms idle grace fixes that lifecycle issue; the
final display-link cases are rerun after the fix.

The GUI matrix uses the authenticated isolated daemon and native capture,
transport, decoder and Metal presentation path. Each run labels its codec,
presentation mode and adaptation setting in `latency.json` (synthetic) or
`input-latency.json` (owned application). The workload is deliberately synthetic;
these measurements are not a matched-quality bandwidth comparison or physical
photon/scanout measurement. Clean-LAN on/off differences alone cannot demonstrate
congestion improvement. The previous 61 ms real-input baseline must only be
compared with the owned-application run, not the synthetic color-toggle test.

```sh
# Full eight-way synthetic matrix (H.264/HEVC x two render modes x fast on/off)
DIETER_TEST_SCREEN_LATENCY_MATRIX=1 just mac screens-test

# The same matrix with real capture and an owned input target
DIETER_TEST_SCREEN_LATENCY_MATRIX=1 DIETER_TEST_SCREEN_CAPTURE_REAL=1 just mac screens-test

# Race-checked unit and actual WebRTC feedback tests
go test -race ./internal/remotedesktop -run 'TestFastBitrate' -count=1 -v

# Hardware tests, including rate changes, input and lifecycle
just mac screens-native-test
just mac test
```

GUI runs retain the existing app guard and use disposable credentials, state and
loopback listeners. They never stop or replace the operator daemon.

## Measured results on this Mac

All eight synthetic configurations passed (display-link rerun after the idle
grace fix), and all eight owned-application configurations passed on the final
renderer. Each real-input row below contains 24 verified pixel responses. These
are exploratory sequential runs on the developer machine, not randomized or
isolated-load performance trials.

| Codec | Presentation | Fast cuts | Real input median | Real input p95 |
|---|---|---|---:|---:|
| H264 | immediate | off | 79.8 ms | 98.4 ms |
| H264 | immediate | on | 63.7 ms | 84.5 ms |
| H264 | display-link | off | 98.0 ms | 120.3 ms |
| H264 | display-link | on | 112.3 ms | 132.5 ms |
| H265 | immediate | off | 62.1 ms | 73.0 ms |
| H265 | immediate | on | 60.8 ms | 73.3 ms |
| H265 | display-link | off | 94.8 ms | 103.0 ms |
| H265 | display-link | on | 113.8 ms | 117.6 ms |

Immediate presentation remains the default: the display-link experiment did not
improve complete-path latency here and reduced HEVC presentation cadence in the
synthetic workload. Keep it opt-in for testing on other displays. With fast cuts
enabled, immediate H.264 measured 63.7/84.5 ms median/p95 and HEVC 60.8/73.3 ms.
The HEVC median is essentially the previous 61 ms baseline; these results do not
establish a new steady-state latency improvement. The confirmed changes are
rendering progress during UI stalls and prompt bitrate configuration after fresh
congestion feedback. Clean-LAN on/off differences are not proof of that congestion
benefit, and no matched-quality bandwidth saving is claimed.

The isolated encrypted TWCC test observed roughly 2 ms from received feedback to
its instrumented encoder Configure call, with control RTT about 35 ms under loss.
Hardware H.264 and HEVC tests separately observed approximately 1.4 and 2.4 ms from
feedback processing to the native configuration ACK. The controller deliberately
coalesces at 100 ms and requires sustained delay evidence; these handoff numbers
do not include waiting for network feedback or time until lower-rate pixels are
presented.

The first drawable can report a presentation event without a usable hardware
timestamp. Visibility delivery and valid timing samples are tracked separately;
a visibility-triggered redraw also handles a static first frame. Only positive
hardware timestamps enter the reported input/render latency samples.

Raw evidence indexes and logs from this run (outside the repository):

- `/tmp/dieter-scheduling-synthetic-results.json`
- `/tmp/dieter-scheduling-real-results.json`
- `/tmp/dieter-scheduling-matrix.log`
- `/tmp/dieter-scheduling-display-link.log`
- `/tmp/dieter-scheduling-real-final.log`
- `/tmp/dieter-fast-network.log`
- `/tmp/dieter-fast-hardware.log`

## Repository checks and lifecycle

- `just check-changed --dry-run` and `just check-changed` were run against the
  entire current working tree, including the earlier HEVC/clipboard work.
- Proto generation, affected Go race tests, Go vet, native hardware tests,
  18 Mac screen tests (including the complete clipboard/reconnect/resize journey
  and authenticated HEVC transport), 622 Mac module tests and 299 Android unit
  tests passed.
- The broad runner stopped at `just ios build`: this Xcode installation lacks
  the iOS 26.5 Simulator platform/destination. Later iOS/Mac smoke and Android
  connected checks in that broad plan therefore did not run. No simulator SDK
  was installed and no operator app was replaced to work around it.
- A final full `internal/remotedesktop` race run with the hardware helper passed
  in 49.6 seconds. The feedback interval gate was then tightened to handle a
  simultaneous timer/notification wakeup, with a fresh real-TWCC regression run.
- Targeted Swift formatting, shell syntax and `git diff --check` passed.
- The canonical `apps/mac/.build/dieter-tests` cache was reused; no build cache
  was deleted. The operator Mac app exited independently during the work,
  enabling the guarded GUI fixtures. The operator daemon was never stopped,
  restarted, installed over or reconfigured. Test apps, input targets and fixture
  helpers were closed; the Android emulator was not launched for this change.

Additional logs: `/tmp/dieter-scheduling-check-changed.log`,
`/tmp/dieter-scheduling-go-final.log`, and
`/tmp/dieter-scheduling-feedback-final.log`.
