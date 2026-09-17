# Screen reference recovery and adaptive FEC — 2026-09-17

Implemented options 4 and 5 through the native capture helper, Go media path,
protobuf/CLI, and Mac and Android receivers. The existing WebRTC UDP transport,
authenticated signaling, and bounded retransmission path remain in use.

## Acknowledged long-term references

- H.264 and HEVC use VideoToolbox LTR when hardware supports it. HEVC tries the
  low-latency encoder mode needed by LTR and can fall back to the previous
  hardware encoder mode if initialization fails.
- Reliable host challenges name the frame ID, display generation, and RTP time.
  Only actual decoder output authorizes an acknowledgement. Feedback is bound
  to the existing authenticated session epoch and increasing sequence.
- Pending challenges are bounded to eight, decoder history to 128 timestamps,
  and challenges expire after two seconds. Native acknowledgement tokens are
  bounded to 256. Disconnect/reconfiguration prevents stale acknowledgements
  from crossing sessions or encoder generations.
- Each LTR viewer has an independent encoder; all viewers still share native
  ScreenCaptureKit capture for a display. Existing four-client/four-encoder
  bounds remain. This costs an encoder per participating viewer.
- Expired retransmissions and PLI/FIR can request an LTR refresh. The negotiated
  generic RTP frame descriptor names the acknowledged dependency, letting native
  WebRTC deliver the recovery frame across a packet gap. HEVC recovery frames
  include VPS/SPS/PPS because its native packet buffer requires parameter sets
  to resume after a gap.
- A missing/expired anchor, unsupported hardware, or an unacknowledged previous
  recovery falls back to a keyframe. Manual refresh and display changes retain
  keyframe behavior. Recovery acknowledgements rearm subsequent LTR repair.

## Adaptive FlexFEC-03

- Negotiated independently of H.264/HEVC, using the pinned native WebRTC receivers.
- Fresh moderate TWCC loss without queue growth selects a 10% or 20% repair-byte
  allowance. Stale feedback, growing queues, excessive loss, or sustained clean
  traffic withdraws protection.
- Encoder bitrate reserves the allowance before repair activates, including
  manual configuration changes. The minimum encoder rate disables FEC when no
  repair allowance fits. Failed encoder configuration cannot enable overhead.
- Media never waits for a parity group. Groups contain at most 12 packets and
  never span frames or retain packets for more than 20 ms of subsequent traffic.
  At most one repair-packet credit accumulates. Retransmissions are not protected
  twice. Repair bytes pass through the same bounded pacer.
- Parity covers final RTP headers, including transport/dependency extensions.
  Repair has a separate negotiated SSRC and no TWCC extension; its bytes use the
  send schedule and allowance, while congestion is observed through media TWCC.

## Validation

Actual VideoToolbox encoding and native WebRTC decoding, 1920×1080 at up to
60 fps, authenticated disposable fixtures:

| Receiver | Codec | LTR decoded after loss | FEC restored deliberately discarded packet |
|---|---|---|---|
| macOS native SDK | H.264 | Pass; keyframe count unchanged | Pass; original and retries blocked |
| macOS native SDK | HEVC | Pass; keyframe count unchanged | Pass; original and retries blocked |
| Android API 37 emulator | H.264 | Pass; decoder acknowledgement returned | Pass; exact decoded RTP time verified |
| Android API 37 emulator | HEVC | Pass; decoder acknowledgement returned | Pass; exact decoded RTP time verified |

The Mac matrix ran baseline, LTR, FEC, and both for each codec. It injected a
whole-frame loss, followed by six seconds of dropping every 25th packet attempt.
All eight cases continued decoding. All four FEC cases separately decoded a
packet whose original and every retransmission were discarded. The proof fixture
can hold one candidate packet for up to 4 ms to select one actually protected by
parity; that targeted proof is not a latency benchmark.

In the LTR cases, the deliberate burst recovered with one total decoded keyframe
(the initial frame), versus two in baseline cases. Maximum inter-decode gaps in
this single matrix ranged from 160–277 ms and were mostly near 260 ms. This
establishes recovery correctness and avoids a keyframe burst; it does **not**
establish a general latency improvement or matched-quality bandwidth saving.
Loss-detection/retransmission deadlines and warmup still dominate those stalls.
The earlier 61 ms real-input median is a different workload and was not remeasured
by this loss test. Physical-device/WAN and controlled repeated latency comparisons
remain necessary before claiming Parsec-like performance.

Go tests cover exact/stale/replayed acknowledgements, per-viewer isolation during
reconfiguration, descriptor dependencies, real encoder recovery/rearm/keyframe
fallback, repair wire-byte limits, congestion withdrawal, and encoder budget
reservation. Native receiver unit tests cover both arrival orders, expiry,
unsigned Android timestamp quantization, bounded histories, and teardown.

Evidence:

- Mac matrix: `/tmp/dieter-recovery-matrix-final.log` (69.9 seconds, eight cases).
- Android integration: `/tmp/dieter-android-screens.2b4RLJ/` with both codec
  screenshots and `recovery.log`; one production-controller UI journey passed.
- Android unit suite: 301 tests, zero failures.
- Affected Go race suite and vet passed, including CLI local/direct-TLS/relay
  coverage. Native helper integration passed (56.2 seconds), including actual
  repeated LTR repair and keyframe fallback. Full check log:
  `/tmp/dieter-recovery-check-changed.log`.
- Mac native integration: 20 tests passed (76.8 seconds), including production
  controller signaling, presentation, reconfiguration, reconnect and clipboard.
  Full Mac module: 626 tests passed. Android full unit suite: 301 passed.
- `just check-changed --dry-run` and `just check-changed` were run. The combined
  check stopped at the iOS build because Xcode lacks the iOS 26.5 simulator
  platform. Subsequent iOS smoke, broad packaged-Mac smoke, and general Android
  connected-suite steps were not reached. The dedicated Mac and Android screen
  recovery integrations above ran separately against disposable fixtures.
- The production Mac controller's synthetic input-to-Metal test reported
  63.2 ms median / 67.4 ms p95 across 24 input samples. This is synthetic H.264;
  it is not a like-for-like comparison to the earlier real-input HEVC baseline.

The task-owned `Pixel_9_API_37_1` / `emulator-5554` was closed with a validated
saved snapshot. Its initially corrupt snapshot was preserved in quarantine,
repaired from existing userdata, and successfully reloaded before testing.
The attached physical phone, saved app credentials, and operator daemon were
untouched. Tests used existing Swift/Gradle caches and disposable fixture roots.

## Operations

`screen status SESSION` and `screen sessions` expose `referenceRecovery`,
`referenceAcks`, emitted `referenceRecoveryFrames`, decoded `referenceRecoveries`,
`fecPercent`, `fecPackets`, and estimated wire `fecBytes` (RTP plus 48-byte
transport allowance). Native clients negotiate automatically. CLI automation can
opt in with `screen start --reference-recovery` and must implement decoder feedback.
Older clients keep keyframe recovery and require no protocol migration.

Run the native matrix with `DIETER_TEST_SCREEN_RECOVERY=1 just mac screens-test`.
Run Android with
`DIETER_SCREEN_TEST_CLASS=com.dbpprt.dieter.screens.ScreenRecoveryEndToEndTest just android screens-test`.
Use `DIETER_SCREEN_LTR=0` or `DIETER_SCREEN_FEC=0` only in disposable processes for
A/B comparison; no operator service restart is required for validation.
