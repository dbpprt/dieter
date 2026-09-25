> **Historical engineering record.** This dated investigation or implementation

> Historical record: Android launcher scripts and test aliases referenced below
> have been retired. Use the [current native test guide](../tests/e2e/README.md)
> for supported commands and selectors.
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Screen performance implementation and evidence

18 September 2026. Implementation starts from `e68087d5`. The working tree
contains the implementation; no operator daemon was replaced or restarted.

**This is a tested implementation of the core mechanisms and experiments, not
completion of every qualification gate in the [plan](screenshare-performance-plan-2026-09-18.md).**
Direct MediaCodec output is now implemented behind a fixture switch; matched-quality
total-wire comparisons, the full physical-device matrix and optical/competitor
qualification remain outstanding.
The evidence does not establish Parsec/Moonlight parity or a universal lowest
latency setting. Failed experiments are retained as evidence, not promoted.

## Implemented behavior and defaults

| Area | Implementation | Production decision |
|---|---|---|
| Mac presentation | Separate GPU/compositor ownership, exact submission IDs, newest-frame mailbox, bounded trace and presentation watchdog. Immediate, display-link, adaptive one/two-presentation and unsynchronized candidates. | Immediate stays default. The strict one-slot candidate broke cadence; its replacement still failed an H.264 latency comparison. |
| Android decode | Pinned-AAR verification; exact selected MediaCodec identity; official low-latency capability/configuration adapter; at most one fresh ordinary-codec retry on configuration or start rejection. Real WebRTC frame callbacks and reference ACKs preserved. | Low-latency option remains fixture-only pending a physical codec that advertises it and demonstrates a benefit. |
| Android output | Session/generation frame gate; TextureView, SurfaceView/EGL, and real MediaCodec direct output with bounded output-index ownership, fixed-size storage and parent cursor composition. | TextureView stays default. Qualcomm codec/fallback/surface-replacement checks pass; combined recovery passes on the tested Qualcomm device; performance qualification remains open. |
| Recovery | Session-wide packet/byte/age bounds, fresh nominated ICE RTT, useful repair deadlines checked after pacing, old-generation repair fencing, bounded retry work and coordinated LTR/IDR scheduling. | Bounded recovery runs normally; existing FEC/reference negotiation remains intact. |
| Codec/bandwidth | Actual decoder/encoder diagnostics and classified RTP counters; metadata-only capture damage, input priority, hysteresis, observed inter-frame cost and bounded idle refinement. | Existing H.264/HEVC admission stays. Content policy stays off; no new automatic HEVC promotion without quality/wire evidence. |
| Encoder/sender | Accepted/rejected burst-envelope diagnostics; negotiated exact-frame/generation credits permit at most one additional encode behind a send. Recheck age, predicted encode time and serialization cost. | Legacy rate envelope and one-credit mode stay default. Short windows and overlap stay off. |

The low-latency Android adapter uses the pinned SDK's package-private codec
wrapper constructor. The direct-surface SDK extension rebuilds four Java classes
and adds two; every runtime class occurs once. All four native JNI libraries
remain byte-for-byte unchanged. The existing JNI bridge retains actual dequeued
surface buffers and preserves normal decode completion, RTP matching and stats.
The [reproducible builder](../native/android-webrtc/README.md) records compiler,
source, input/output AAR and native-library hashes. A repeated build produced the
same output AAR. This is not a native WebRTC source rebuild.
The final repeated AAR was `e5065dd4b157f8762517efcbbd536bb8d58b5818fa7aa3125002e5a65d52c12c`;
BSD/patent notices are present in both the AAR and installed fixture APK.
The package/version, AAR SHA-256, verification task and reproduction steps are in
[the decoder contract](../apps/android/webrtc-adapter.md). Fallback covers
configure rejection, start rejection, ordinary-mode failure and replacement
allocation failure; cleanup does not release an already retired codec twice.

An Android frame that arrives before reliable generation metadata is retained
once and released on replacement, delivery or session reset. The RTP boundary
decides whether that real decoded frame belongs to the new display. This avoids
discarding an idle display's only frame while preserving texture ownership.

Recovery history holds at most 4,096 packets and 4 MiB of serialized RTP
headers/payload across at most four SSRCs. Useful history age is at most 250 ms;
an idle cache may retain bounded expired storage until replacement/close.
One worker has a 64-entry pending queue and at most two repair attempts per
packet. Padding tombstones prevent missing probes from forcing refreshes.
With fresh RTT, the useful window is clamped to 50–250 ms; old/unknown timing
uses the compatibility window. IDRs are throttled independently of LTR attempts.
A missing reference-recovery ACK now schedules one generation/attempt-fenced
IDR fallback after a bounded admission/ACK interval, respecting the independent 200 ms IDR
throttle. It no longer requires another NACK/PLI to make progress. Actual native
H.264/HEVC tests withhold the second recovery ACK and send no further request;
the helper must emit the fallback within 500 ms of encoded recovery output. Fake-clock checks cover exact
deadlines, duplicate expiry and ACK cancellation. Generation changes clear old history; repairs check generation again after a
pacer wait. These bounds describe payload storage, not exact process RSS.

Native overlap requires explicit helper capability advertisement and a
`frame_sending` command with the exact generation/frame ID. Old peers keep the
one-credit behavior. Credits cap access units at 16 MiB each, with at most two
outstanding, and permit speculative overlap only behind an access unit at most
2 MiB with a 1–50 ms budget and fresh raw pixels. No arbitrary encoded reference
frame is replaced. A real hardware integration test distinguishes overlapped
output using an additive flag without changing the binary frame-header layout.

## Measurement contract

The schema additions are additive and regenerated for Go/Swift; Android builds
from the authoritative proto. Existing status RPC/CLI operations expose them,
including local, authenticated direct-TLS and gateway-relay routes. No new
production trace endpoint or gateway storage was introduced.

- `METAL_PRESENTED` ends at the drawable's presentation timestamp.
- `EGL_SUBMITTED` ends at Android EGL draw/swap submission. It is not presentation
  or scanout. `ANDROID_FRAME_RENDERED` ends at the real MediaCodec frame-render
  callback timestamp on the direct path; callbacks may be delayed/batched and
  do not measure physical scanout.
- Optional decoder hardware/low-latency booleans distinguish unknown from false.
  Configuration acceptance is not evidence of lower measured latency.
- Direct Android releases explicitly use the current local monotonic timestamp.
  Testing caught the boolean release overload propagating RTP media PTS as the
  surface timestamp: an emulator produced a huge false duration and a phone's
  negative duration had been clamped to zero. Both are invalid timing evidence.
  Current code uses the timed overload with **now**, validates callback time
  against release/callback bounds, and falls back if valid callbacks are absent.
- Media, repair, probe and FEC byte counters count successful serialized RTP
  headers/extensions, payload and padding. They exclude SRTP, RTCP, SCTP, ICE,
  UDP/IP and TURN overhead. **They are not total wire-byte measurements.**
- Damage fraction measures changed capture area, not semantic text or quality.
  Unknown/stale samples stay unknown. Repeated sequences cannot refresh age.
- The Mac trace holds at most 4,096 numerical records and no screen/input content.
  GPU timing, drawable acquisition and presentation callback time remain separate.
  A 100 ms watchdog can retire presentation accounting but never GPU ownership.

`scripts/qualify_screens.py` records revision, working-tree/source hashes,
hardware/OS identity, exact switches, test status and bounded allowlisted
artifacts. It accepts known exact-argv runners, requires explicit physical phone
serials, rejects missing required evidence, and fails a failing baseline
comparison. Comparisons require finite measurements with complete codec,
geometry and endpoint identity; motion cases require actual cadence. Recovery
acceptance verifies all eight Mac cells and four exact-frame FEC proofs, or both
Android codecs with actual decode/reference completion and matching protected
RTP identity. An incomplete artifact or successful runner summary alone cannot
pass. The runner fingerprints source before and after the run and fails if it
changed. It does not promote defaults. The supplied manifest is a **local
fixture manifest**, not a waiver of external qualification requirements.
It now selects the retained immediate Mac policy and requires every declared
local Android codec, SDK, surface, journey and recovery case. The SDK runner
checks fresh JUnit results from all three codec/ownership/launcher classes and
rejects skipped tests before publishing its evidence.
Its final standalone artifact-collection recheck was **unavailable**: the shared
physical phone remained leased during a bounded ten-minute wait. The identical
16 selected tests had already passed through the direct Gradle invocation, but
that does not count as an end-to-end pass of the new wrapper. Its shell syntax,
qualification command contract and planner selection checks pass.

## Measured Mac policy comparison

Apple M4, macOS 26.5.1; same-host authenticated fixtures; 1440×810; 60 fps ceiling;
200 pixel-verified input responses per cell. Baseline here means the immediate
policy on the instrumented implementation, **not an unmodified release build**.
These are individual paired runs, not the plan's repeated randomized qualification.

| Policy / scene | Median input → Metal | p95 input → Metal | Achieved motion fps |
|---|---:|---:|---:|
| Immediate, synthetic H.264 | 46.66 ms | 65.90 ms | 60.46 |
| Strict one outstanding, synthetic H.264 | 43.28 ms | 80.69 ms | **24.54** |
| Adaptive one/two, synthetic H.264 | 53.36 ms | **77.07 ms** | 60.15 |
| Immediate, synthetic HEVC | 45.95 ms | 67.09 ms | 59.87 |
| Strict one outstanding, synthetic HEVC | 41.40 ms | 74.94 ms | **39.61** |
| Adaptive one/two, synthetic HEVC | 44.76 ms | 64.99 ms | 60.19 |
| Immediate, real application H.264 input | 73.10 ms | 101.28 ms | Not a sustained-motion measurement |
| Adaptive one/two, real application H.264 input | 65.78 ms | 84.52 ms | Not a sustained-motion measurement |
| Unsynchronized, synthetic H.264 | 58.37 ms | 69.43 ms | 59.25 |
| Unsynchronized, synthetic HEVC | 57.25 ms | 69.59 ms | 59.40 |
| Unsynchronized, real application H.264 input | 80.46 ms | 98.92 ms | Not a sustained-motion measurement |
| Display link, synthetic H.264 | 78.85 ms | 104.37 ms | **30.37** |
| Display link, synthetic HEVC | 79.91 ms | 105.61 ms | **23.90** |
| Display link, real application H.264 input | 115.07 ms | 128.91 ms | Not a sustained-motion measurement |

The strict candidate failed cadence. Traces showed presentation intervals moving
from about 16.7 to 33.3 ms while callback delay remained around 0.5 ms: waiting
for a single compositor presentation prevented sufficient pipelining. The revised
candidate restores approximately 60 fps, but H.264 p95 regresses by 11.17 ms,
exceeding the frozen 5 ms gate. It therefore remains off. Lower real-input latency
in one cell cannot cancel the failed cell. The original presentation-delay
problem is **not declared solved** by these experiments.

Stage-aligned trace analysis localizes most remaining motion residence after
GPU completion. Immediate H.264 had median 5.16 ms decode-to-commit, 0.82 ms
commit-to-GPU-complete, and 30.31 ms GPU-complete-to-Metal-presentation;
presentation callback dispatch added only 0.43 ms. Immediate HEVC's corresponding
medians were 0.34, 0.77, 29.97 and 0.42 ms. These per-stage distributions come
from the same traces, but their separate medians must not be summed into an
end-to-end percentile. A faster shader or codec cannot remove that compositor
residence; synchronized/display-link and unsynchronized policies still need
controlled comparison. Detailed distributions are in `mac-stage-analysis.json`.

The later unsynchronized run passed the limited p95/cadence comparison but did
not consistently improve input latency. H.264 GPU-to-presentation median remained
31.68 ms. It remains an experiment; this is not a tearing/optical qualification
or a randomized paired result, and does not justify a default change.
The display-link candidate failed both motion cadence assertions; H.264's
GPU-to-presentation median reached 48.87 ms. Its real-input p95 also worsened by
27.63 ms. It is rejected on this host under the tested settings, not silently
promoted because the API offers a latency preference.

An exploratory combined run (bounded presentation, content policy, overlap,
250 ms burst envelope) passed with 200 synthetic input probes at 57.28 ms median /
80.05 ms p95. It is correctness/experiment evidence, not a qualifying speedup.
Earlier uncontrolled 24-probe and concurrent-build measurements are not used to
choose a default. Metal timestamps also cannot establish physical tearing or
input-to-photon performance.

Local evidence: `/tmp/dieter-screen-implementation-20260918/`, especially
`qualification-baseline`, `qualification-bounded`, `qualification-adaptive`,
`mac-combined-synthetic.log`, `mac-recovery-combined.log` and `native-latest.log`.
Temporary evidence is not durable release storage; numerical findings above
are retained here. Credentials/ready files are excluded from qualification copies.

## End-to-end coverage

Verified during this implementation:

- Native helper input/credit state tests and real hardware capture/encode Go race
  suite: passed (58.845 s in the latest hardware run). Negotiated overlap is
  observed; legacy mode remains single-credit.
- Mac full unit/component suite: **657 tests passed**. Native screen suite:
  **25 tests passed**, including actual viewer, recovery/reconnect/lifecycle,
  authenticated HEVC transport and presentation state-machine tests.
- H.264/HEVC native recovery matrix: **all eight codec × baseline/LTR/FEC/both
  cells passed**, including actual FEC decode with originals and repairs dropped.
  The matrix was repeated after the final two-phase ACK timeout and passed in 72.076 s.
  Recovery timing measurements are not a matched baseline improvement claim.
- Android unit suite: **304 tests passed**, including a run against the Java SDK
  extension. Physical codec/ownership instrumentation: **15 tests passed**; the earlier
  emulator SDK run passed 14 tests,
  including bounded rejection/recreation, cleanup, two-buffer ownership,
  index reuse, late callbacks, borrowed-surface lifetime, opaque surface format,
  failed-worker reinitialization, direct-to-texture configuration fallback,
  foreign-clock rejection, late output after a five-second shutdown timeout,
  and actual output-dequeue observation while texture delivery is stalled.
  After the launcher namespace fix, all 304 unit tests and the debug build passed
  again; a physical run passed the 15 SDK checks plus the new launcher regression
  (**16 tests**, no failures).
- Samsung SM-S928B / Android 16: actual Qualcomm H.264 and HEVC decode, automatic
  fallback/reconnect and strict unsupported-HEVC-mode rejection passed. The actual
  codecs are `c2.qti.avc.decoder` and `c2.qti.hevc.decoder`; neither advertises the
  official low-latency feature, so ordinary decoding is correctly retained.
- Physical phone real direct H.264/HEVC codec selection, fallback and reconnect
  passed (27 s with the corrected surface clock); the equivalent emulator journey
  passed (25 s). Both codecs report `ANDROID_FRAME_RENDERED` and nonzero native
  `framesDecoded`. Withholding actual direct outputs triggers one texture
  fallback; destroying/recreating the real SurfaceHolder restores direct output.
  Owned-layer screenshots
  show actual video and cursor. The first run caught an opaque-format validation
  bug; the SDK now validates CPU color formats only for byte-buffer output.
  The initial full direct journey reached disconnect, where its screenshot
  helper tried to copy a covered empty surface. Capture now includes only the
  active visible video layer; the full synthetic direct journey subsequently
  passed on phone (68 s) and emulator (70 s). These pre-clock-fix runs establish
  interaction correctness, not valid direct timing. The corrected-clock real
  ScreenCaptureKit/input journey subsequently passed on the physical phone
  (65 s), with actual `ANDROID_FRAME_RENDERED` feedback; its screenshot was
  inspected. The final output-observer SDK also passed the physical real-input journey
  (64 s), direct codec/lifecycle and ordinary-texture codec regression.
- Physical phone full TextureView and SurfaceView/EGL journeys passed: video,
  cursor, pan/pinch, clipboard text/images/files, keyboard, control, configuration,
  session expiry/recovery and repeated disconnect/reconnect. Owned-window and
  owned-surface PixelCopy evidence was inspected. This is not optical timing.
- Physical phone combined recovery passed with content adaptation, overlap and
  the 250 ms burst envelope enabled. Both codecs decoded/ACKed LTR recovery and
  FEC reconstructions with original packets and retransmissions discarded on
  texture output. The direct path also passed exact H.264/HEVC FEC proof after requiring
  continuous decode before the isolated probe. Repeated checks exposed two
  additional sources of ambiguity: protection can retire while a prior recovery
  stalls, and texture output may be discarded before the old frame observer.
  The SDK now observes actual MediaCodec dequeue independently of presentation,
  deduplicates reference history, and the helper has bounded ACK-timeout fallback.
  The final SDK passed physical baseline direct and texture recovery. Combined
  HEVC uncovered an ACK-budget boundary: encode time must not consume the
  receiver's acknowledgement interval. The helper now rearms once upon actual
  recovery output, with a separately bounded admission interval. The combined
  H.264/HEVC case then passed three consecutive times. These are
  correctness checks, not a claim of full recovery qualification. Structured recovery evidence records
  exact protected/decoded RTP identity and continuity/probe timings. A separate
  fixture regression fixes its four-millisecond hold expiring before paced FEC;
  only one selected test packet may now wait up to 250 ms for parity. Production
  media is not held by this proof mechanism.
  Final direct and ordinary-texture H.264/HEVC runs also passed with complete
  structured evidence after the launcher fix. Direct output reported
  `ANDROID_FRAME_RENDERED`; texture output reported `EGL_SUBMITTED`.
- Emulator **and physical Samsung** real-ScreenCaptureKit journeys passed, verifying actual desktop pixels
  and host receipt of relative clicks, Unicode text, special keys, three-finger
  scroll, clipboard paste and held-key release. It is correctness evidence only.
- CLI package race suite passed, including the new diagnostics assertion over
  local/direct-TLS/relay sessions with actual ICE establishment. `go vet ./...`
  passed. Qualification/planner tests passed (5 and 31 tests).

The phone fixture uses `com.dbpprt.dieter.screenfixture`, preserving the operator
application. The ordinary wrapper retains its emulator-only guard. Screenshots
use the fixture's own window/surface instead of registering a competing global
UiAutomation service. A failed screenshot cannot hide the original assertion.
The clipboard journey now waits for the current manual operation to finish;
an earlier background-sync error cannot prematurely fail that operation.
The owned host input fixture also resets an earlier binary selection on typing;
real-screen Copy now verifies newly received text instead of a stale attachment.

A later repeated phone run exposed a launcher-alias crash before screen
startup: an application-ID suffix does not change the manifest's activity class
namespace. Alias resolution now uses the application class namespace while
retaining the installed package identity. A dedicated instrumentation regression
hydrates the persisted preferences and resolves the enabled real manifest alias.
That regression and both recovery paths now pass. The failed startup logs are
retained separately from media-recovery evidence.
An earlier texture instrumentation pass also failed artifact collection because
the shell runner was edited during execution; it is not accepted as a complete
fixture pass. Runners and runtime inputs must remain unchanged while executing.

The emulator later failed to restore `default_boot`. The documented repair
quarantined the exact corrupt snapshot and stale locks on the external AVD
volume, preserving userdata. Its one recovery launch paused at the emulator's
crash-report consent dialog before Android boot; the UI tool could not address
that executable, so the exact owned process was stopped without a snapshot
save. A healthy save/reload is still unavailable; earlier emulator passes do
not certify the latest output-observer extension. Physical checks acquire the shared phone lease and never preempt the other task.

The internal disk also filled during a later Mac build. Generated Android build
outputs were preserved on the external volume with the original workspace path
symlinked; no app data or compilation cache was deleted. The Mac recovery
matrix then ran successfully.

The broad changed-check run is **not globally green**:

- Initial Go failures were caused by the internal disk dropping below the
  repository's 2 GiB turn-admission guard. Disposable tests were rerun on the
  external volume; app/gateway/scheduler and the affected screen/CLI suites pass.
- An unchanged server test expects the substring `automatic update`, while the
  unchanged implementation returns `automatic daemon updates …`; a separate
  temporary-directory cleanup race also appeared. These are recorded separately
  from screen results rather than hidden by a success summary.
- The Mac conversation smoke suite failed `content-code-line-link` and
  `content-terminal-input`; a separate repeat also reported editor/markup
  interaction failures. These UI failures are not fixed by this screen change.
  Core/board and the separately run remaining suites
  are recorded in `mac-smoke-all.log` / `mac-smoke-remaining.log`.
- Five general Android connected tests require authenticated live-gateway access
  and failed `UNAUTHENTICATED`. Tests requiring other dedicated fixtures report
  skipped. Isolated screen fixtures use disposable credentials and run separately.
- iOS build/phone/iPad checks are unavailable: Xcode lacks the required iOS 26.5
  platform. No platform download or operator credential change was attempted.

## Remaining gates, not waived

| Plan slices | Still required |
|---|---|
| P00 | Fully aligned cross-stage trace contract, richer quality corpus, isolated two-host/network-impairment fixture, total-wire accounting, trace-overhead and repeated randomized baselines. |
| P01–P02 | Repeat latency/cadence/display/idle comparisons, diagnose remaining compositor residence, physical tearing/scanout, 120 Hz and additional display/hardware qualification. |
| P03–P04 | An advertising physical low-latency codec; matched direct-output A/B latency runs; orientation/lock/background/power qualification across codec families. Direct/texture codec fallback, SurfaceHolder replacement and both-codec recovery pass on the tested Qualcomm phone. |
| P05–P06 | Matched loss/RTT/capacity matrix proving recovery improvement and bounded observed network overhead on impaired real transport. |
| P07–P08 | Matched-quality HEVC/H.264 wire savings and automatic-selection allowlist; rich text/motion/capacity transitions and long stability runs. |
| P09–P10 | Burst quality measurements and comparative constrained-sender frame-age/latency/fairness evidence; longer multi-viewer resource soak. |
| P11 | Complete physical/network/compatibility matrix, optical Parsec/Moonlight comparison and release/default decision. |

No direct-surface or physical frame-render callback is fabricated to close a
checkbox. No bandwidth saving, power benefit or competitor parity is inferred
from synthetic gray pixels or codec-setting acceptance.

Final local recovery evidence includes `mac-recovery-produced-final.log`,
`native-recovery-final.log`, `android-accepted-final-results.json` and the
checksummed `evidence-audit.json` under the evidence root above. The latter
verifies the final direct/texture H.264/HEVC records and the three combined
recovery repeats. `validation-summary.json` distinguishes earlier runs, current
passing cases, unrelated broad-check failures and unavailable qualification.
These are multiple scoped runs, not a single source-frozen full-manifest pass.
