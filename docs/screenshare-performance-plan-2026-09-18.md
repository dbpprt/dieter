# Screen-sharing performance implementation plan

Date: 18 September 2026. Status: planned; no runtime changes are made by this document.

Implementation progress, measured rejected candidates, passing fixtures and
remaining gates are tracked in the [implementation evidence](screenshare-performance-implementation-2026-09-18.md).
That report does not mark all P00–P11 qualification gates complete.

Implement the five priorities from the investigation summary end to end, with measured promotion of defaults:

1. **Mac presentation:** remove avoidable decoded-frame/compositor residence.
2. **Android decode and presentation:** enable supported low-latency decoding and evaluate direct-surface output on physical devices.
3. **Loss recovery:** recover before a frame becomes useless, with bounded NACK/FEC/LTR/IDR work.
4. **Codec and bandwidth policy:** choose hardware HEVC when it wins, and spend bandwidth according to content and interaction.
5. **Encoder and sender scheduling:** control bursts and overlap useful work without accumulating old encoded frames.

These numbers refer to the five items discussed in the conversation. The [investigation](screenshare-performance-investigation-2026-09-18.md) groups Mac and Android together under its first heading; its heading numbers are different. Input, clipboard, cursor, multiple viewers, permissions, and reconnect behavior are cross-cutting requirements for all five items.

The optimization objective is **minimum wire bandwidth at an accepted visual quality, frame cadence, and latency deadline**. No single setting minimizes bandwidth, latency, and compute simultaneously. A candidate is complete when it is implemented, tested, and either qualified for specific devices/workloads or rejected with evidence. Shipping an unhelpful tuning change is not a completion requirement.

## Starting evidence and scope

The September 18 baseline is exploratory: Apple M4, macOS 26.5.1, same-host loopback, 1440×810 at a 60 fps ceiling. Real application input-to-Metal presentation was 65.46 ms median / 82.44 ms p95 over 24 responses. Synthetic capture-to-presentation was 55.48 / 73.73 ms. A final interval reported approximately 40 ms render residence, 4 ms encoding, and sub-millisecond sending/jitter-buffer residence. These windows are different; they cannot be added into an exact pipeline. Re-establish a controlled baseline before using these numbers as acceptance criteria.

Existing capabilities remain the foundation: shared ScreenCaptureKit surfaces, required hardware VideoToolbox encoding, GPU-native rendering, WebRTC/ICE/SRTP, TWCC congestion feedback, FEC, acknowledged reference recovery, separate local cursor handling, and bounded queues. Do not rebuild these features as if they were absent.

This release covers the existing SDR H.264 and HEVC modes and existing maximum supported geometries/cadences. HEVC automatic selection initially retains its current 1080p60 ceiling. Higher HEVC modes, AV1, HDR/4:4:4, temporal layers, ROI/tile refinement, audio, new host operating systems, and a new transport are separate projects. They are not prerequisites for completing these five priorities. If a residual receiver delay requires a WebRTC patch, make it a narrow, measured change within this plan.

## Delivery sequence

Each slice must build and pass its scoped checks independently. Keep experiment switches independent until final integration so a regression can be attributed to one change. This is an execution order, not a request to create tasks or start implementation now.

| Slice | Deliverable | Depends on | Required evidence before merge/promotion |
|---|---|---|---|
| P00 | Measurement contract, fixtures, baseline, resource budget | — | Reproducible aligned traces; honest skip reporting; baseline artifacts |
| P01 | Mac presentation instrumentation and lifecycle state machine | P00 | Deterministic completion-order tests; actual presented-frame identity |
| P02 | Mac scheduling candidates and selected policy | P01 | Repeated real-input/idle/cadence/display tests; selected default justified |
| P03 | Reproducible Android decoder patch and capability fallback | P00 | Pinned binary verification; physical low-latency configuration tests |
| P04 | Android surface path and presentation measurement | P03 | Physical-device A/B, surface lifecycle, input/overlay compatibility |
| P05 | Recovery deadline model and bounded history sizing | P00 | Fake-clock policy tests plus real native decode recovery |
| P06 | Integrated FEC/NACK/LTR/IDR arbitration | P05 | Random/burst-loss matrix, bounded overhead, shorter visible stalls |
| P07 | Codec qualification and automatic selection | P02, P04, P06 | Matched-quality hardware results; first-frame and fallback journeys |
| P08 | Content-aware bandwidth controller | P07 | Text/motion/idle transitions; capacity steps; no controller oscillation |
| P09 | Encoder capability reporting and burst envelope | P00, P06 | Accepted-setting diagnostics; encoded output and quality measurements |
| P10 | Negotiated bounded encode/send overlap and sender tuning | P08, P09 | Backpressure/reference/cancellation tests; frame-age improvement |
| P11 | Combined qualification, documentation, default rollout | P02, P04, P06, P08, P10 | Complete mandatory E2E cells, compatibility, soak, release evidence |

P01–P06 can be developed independently after the shared contracts settle. P09 can also be evaluated early, but combined defaults are selected only after P08/P10. Do not mix protocol changes, a decoder dependency update, and multiple controller changes into one unreviewable patch.

## P00 — trustworthy measurement and test infrastructure

### Define the measurements before optimizing

Create one versioned performance-result schema and a short metric glossary used by Go, Swift, Kotlin, CLI output, and test reports. Every record carries run ID, session ID, media/display generation, frame identity, and the local clock domain. Input probes additionally carry the input ordinal. Preserve RTP wraparound and Android timestamp quantization semantics.

Record the following stages with a bounded per-session trace ring:

| Host | Receiver | User-visible outcome |
|---|---|---|
| Input receipt/injection; capture timestamp and callback; scale start/end; encode admission/start/output; pipe receipt; first/last media packet send | Frame assembly/decode input where exposed; decoder output; mailbox offer/take; drawable wait; GPU commit/completion; surface release/submission; presentation callback | Pixel-verified input response; capture-to-present where clocks permit; inter-presentation gap; first frame; idle resume; stale frame rejected |

Also record actual codec/hardware identity, enabled and rejected encoder/decoder options, resolution/FPS, candidate-pair protocol and relay protocol, fresh RTT age, loss, useful/expired repair, recovery type, keyframe sizes, queued bytes, unpresented frame count, and drops by reason. Record media, retransmission, parity, probe, RTCP, SCTP, and available network-layer overhead separately. Distinguish estimated transport bytes from measured wire bytes; include relay encapsulation when comparing bandwidth.

Rules:

- Mac GPU completion is not presentation. Android EGL submission is not presentation. Keep separately named metrics; never reinterpret the existing `render_ms` field silently. Add explicit validity/measurement-kind fields and new timing fields where necessary, retaining legacy behavior for old peers.
- Client input-to-presentation can use one client monotonic clock plus the echoed pixel marker. Cross-host stage subtraction requires measured clock offset/drift with uncertainty; omit precise stage claims when uncertainty is too large. Physical scanout is a separate optical measurement.
- Missing, stale, zero-resolution, and unsupported measurements are distinct from a real zero. Repeated feedback must not refresh the age of an old sample.
- Use bounded numerical traces, off the critical path. Start with at most 8,192 trace events / 1 MiB per session, overwriting oldest records and counting loss. Detailed tracing is opt-in; normal statistics are aggregated. Benchmark tracing on/off; target less than 1 ms p95 input-latency overhead and less than 2% relative CPU overhead on the baseline machine. If overhead is larger, reduce sampling or report separate minimally instrumented performance runs.
- Test artifacts go to the runner's evidence directory. Any product diagnostics use bounded retention under `DIETER_HOME`; no project metadata, raw screen content, clipboard data, keystrokes, or credentials enter production traces. Pixel captures are restricted to deterministic owned test scenes.

Extend existing session state/feedback messages additively in `api/proto/dieter/v1/dieter.proto`; regenerate with `just proto`. Use existing session inspection operations for aggregated diagnostics. Keep high-rate traces local to the test fixture initially. If a new product diagnostics operation is added, implement the complete gRPC/Connect/CLI/help contract in the same slice; do not sneak in a fixture endpoint as a production API.

### Build reproducible fixtures

Extend `scripts/screens-fixture/main.go`, the owned native input target, and existing Mac/Android screen test drivers. Add deterministic scenes for small grayscale/colored text, terminal scrolling, window dragging, cursor-only movement, animation/video, noisy motion, and static → interaction → static. Encode a frame/input identity in a robust visible patch and verify the identity after presentation. Measure the local non-streamed application response too.

The existing loopback fixture cannot stand in for a remote-machine benchmark. Add an isolated two-machine fixture using disposable enrolled identities, authenticated direct TLS and an isolated gateway. Keep the raw daemon API loopback-only. Bind any test control endpoint to loopback and carry remote control through authenticated fixture infrastructure. No public unauthenticated test endpoint.

Use two impairment layers:

1. Seeded in-process packet/feedback faults for deterministic policy and native protocol tests, extending existing media-loss injection.
2. A fixture-owned UDP path or isolated network appliance for bottleneck capacity, delay, queue, reordering, and bidirectional loss. It must impair actual media/control traffic and report observed traffic. Sender-side RTP drops alone do not model Wi-Fi queueing, uplink ACK loss, or TCP relay stalls. Do not change global host network/firewall settings or the operator's routes.

Preserve the emulator-only safety guard in `scripts/test-android-screens.sh`. Add a separate physical-device runner with an explicit serial, a dedicated test application identity/build where needed, disposable credentials, exact process/port ownership, and no changes to saved operator credentials. An attached phone must never be selected implicitly by Gradle.

Every required test case reports **passed, failed, skipped, or unavailable**, with a reason and artifact path. A required case that did not execute fails the qualification manifest even if the language test runner exits successfully. Fix current opt-in early-return ambiguity before accepting matrix results.

### Freeze the baseline

For baseline and final comparisons: fixed viewport, display refresh/scaling, codec, bitrate policy, app scene, route, power state, and impairment seed; 10-second warmup; at least three randomized paired runs and 200 input probes per run for input percentiles. Capture at least 60 seconds of steady motion and 30 seconds of idle per relevant case. Treat runs, not correlated frames, as independent observations; report per-run results and uncertainty. Repeat noisy or contradictory cases before choosing defaults.

Store revision and dirty-diff identity, compiler/build mode, OS/device/GPU/codec versions, actual negotiated features, exact switches, and scene/impairment seeds. Include p50/p95/p99, sample counts, drop/freeze distributions, quality crops, wire bytes, CPU/GPU, memory, and thermal state. Pin the baseline build for comparison instead of comparing a final build against a shifting working tree.

## 1 — Mac presentation: P01–P02

Primary files: `RemoteDesktopMetalRenderer.swift`, `RemoteDesktopRenderMailbox.swift`, `RemoteDesktopRenderExecutor.swift`, and `RemoteDesktopMetalView.swift` under `apps/mac/Sources/DieterMac/Networking/`; corresponding scheduling and end-to-end tests.

### Implement explicit ownership

Model GPU ownership and outstanding presentation independently. Assign each submission a unique ID and render epoch. A GPU-completed frame can still await compositor presentation; a presentation callback must refer to its exact submission, not a reused mutable “current frame.” Continue replacing the single pending decoded surface with the newest frame.

The state machine must handle GPU/presentation callbacks in either order, delayed or missing presentation notifications, zero presentation timestamps, reset during GPU work, resize, detach/reattach, display migration, occlusion, sleep/wake, and renderer shutdown. Old callbacks may release their own resources but cannot update the new epoch's visible-frame statistics or reopen a closed renderer. A bounded timeout can invalidate presentation accounting and reinitialize a stalled path; it must not release GPU-owned resources before GPU completion. No synchronous wait on the UI thread or presentation callback.

Keep `maximumDrawableCount = 2`; one drawable is not a supported substitute. Keep the private render executor and avoid blocking the main thread. Instrument drawable acquisition before moving it: the existing immediate path already takes the newest mailbox frame after acquiring the drawable, which is useful freshness behavior.

### Evaluate three controlled policies

1. Current immediate rendering with the ownership fixes and complete trace.
2. Synchronized presentation with a strict outstanding-presentation budget, scheduling enough GPU work before the useful display deadline. Compare one versus two outstanding presentations in fixtures; avoid a naïve “wait for presentation, then start everything” policy that halves cadence.
3. Explicit unsynchronized presentation using `displaySyncEnabled = false` where supported. Set `presentsWithTransaction = false` explicitly for clarity, while recognizing it already defaults false. Measure actual benefit and tearing on each qualified display/OS.

Refine the existing display-link candidate only if traces justify it; its prior results were slower. Do not make it the default because the API sounds lower latency. Compare idle wake and missed deadlines as well as average motion.

Choose the lowest-latency synchronized policy that preserves cadence and visual correctness as the normal default. If unsynchronized presentation wins but can tear, expose a clearly labeled local “Lowest latency” presentation preference with that tradeoff. This is a client rendering preference, not a new daemon operation. Preserve a known-good immediate-policy fallback.

### Required tests and exit gate

- Pure state-machine tests exercise callback ordering, duplicate callbacks, deadline expiry, closed epochs, slow GPU, and thousands of pending-frame replacements. Retained frames/drawables stay within the documented bounds.
- Actual native tests verify frame identity at Metal presentation, input-to-present, first frame, idle resume, 60/120 Hz cadence, live resize, Retina scaling, undock/redock, display changes, and a busy main thread.
- Optical checks on qualified displays assess tearing and input-to-photon; Metal timestamps alone cannot establish scanout behavior.
- Qualify H.264 and HEVC. Select defaults using repeated input/presentation distributions, not GPU completion time. A lower render statistic with worse visible cadence fails.

P02 is complete when the selected policy and fallback pass lifecycle tests, avoidable presentation residence is removed, and any remaining display-imposed delay is supported by aligned traces. If the delay is inside another stage, implement and validate that fix before closing P02; identifying it alone is not completion. Do not declare the original ~40 ms issue solved merely because a property changed.

## 2 — Android decode and presentation: P03–P04

Primary files: `ScreenDecoderFactory.kt`, `ScreenCanvasView.kt`, `ScreenController.kt`, Android screen feedback/reference code, and `apps/android/gradle/libs.versions.toml`.

### Make the codec configuration reproducible

The bundled `io.github.webrtc-sdk:android:150.7871.01` decoder does not set MediaCodec's low-latency option. Maintain a narrow, reproducibly built patch to the pinned WebRTC dependency that exposes decoder configuration and surface output hooks. Check in the patch, source revision, build recipe, license/notice changes, artifact digest, and verification test. Avoid reflection into private SDK internals or silently switching to an unrelated SDK revision. First deliver the low-latency option while retaining the existing texture path.

On supported Android API levels, query codec capabilities and try the official low-latency setting. Record requested/accepted/observed behavior separately. Try priority/operating-rate settings individually only where supported and beneficial. Start with standard options; vendor-specific options require a named codec/device/OS qualification and a fallback test. Do not copy an unverified vendor-key list.

If configuration fails, recreate the codec once with the optional setting removed. Bound attempts and report why the feature is disabled. Preserve the existing H.264 software fallback for compatibility, but identify it clearly and lower workload when necessary; never report it as hardware performance. HEVC remains hardware-gated. Preserve the normal WebRTC decoder callback, statistics, RTP/generation matching, and acknowledged-reference behavior.

### Introduce a surface path behind a separate switch

Implement two adapters with one lifecycle/feedback contract:

- Existing shared-texture/EGL/TextureView path, with low-latency codec settings where qualified.
- MediaCodec direct output to an owned SurfaceView surface, avoiding the intermediate texture/EGL composition where the device benefits.

For the direct path, do not fabricate a decoded `VideoFrame` merely to satisfy an old callback shape. The pinned SDK patch must expose a correct surface-backed output/completion contract to WebRTC, including dimensions, timestamps, decode completion, release, and statistics. An LTR acknowledgement requires real decoder output; enqueuing compressed input is insufficient. Dropping obsolete **decoded output** is permitted; arbitrary compressed-reference drops are not.

Associate all surface/codec callbacks with session and surface generations. Surface destruction, orientation, background/foreground, lock/unlock, disconnect, and codec replacement must drain/release ownership exactly once and prevent old output appearing on the new surface. Use nonblocking output release; avoid a deep future presentation queue. Preserve zoom/pan/crop, cursor layering, touch coordinate mapping, accessibility controls, and aspect ratio. Fall back to the texture path if a required composition capability is not correct on a device.

Record decoder output, output release, EGL submission where applicable, and platform frame-render callbacks as distinct timings. Platform render callbacks can be delayed or batched; validate them against optical measurements rather than calling them physical photon time.

### Required tests and exit gate

- Unit/fake-codec tests: option support/rejection, bounded retry, decoder identity, timestamp wrap/quantization, reference ACK after actual output, late callbacks, and surface ownership.
- Existing emulator journeys: connection, controls, gestures, overlays, resize/rotation, codec fallback, reconnect, and teardown. Emulator results do not qualify decoder latency or power.
- Physical devices spanning at least Qualcomm, MediaTek, and a Tensor/Exynos-class implementation available in the supported fleet; include a device without usable low-latency mode and a lower-end fallback case. Record actual codec names; brand alone is not evidence of decoder behavior.
- A/B all supported combinations: original texture path, patched texture path, and direct surface; H.264 and HEVC; 60 Hz and supported high refresh; battery and sustained thermal load.

Promote direct surface or low-latency options only for qualified capability/device classes. All devices retain a tested working path. A device with lower decode time but worse full input latency, power, or rendering correctness does not pass.

## 3 — deadline-driven recovery: P05–P06

Primary files: `pacer.go`, `retransmission.go`, `reference_recovery.go`, `fec.go`, `session_configuration.go`, `network_test.go`, and native Mac/Android recovery tests in the existing screen test suites.

### Make repair usefulness explicit

Replace scattered age thresholds with one recovery decision model using fresh RTT, frame cadence, estimated remaining transit/decode/presentation time, current dependency health, and a bounded frame-age objective. Distinguish the retransmission history's retention limit from the deadline for attempting repair. Retaining a packet for 250 ms does not mean waiting 250 ms before recovery.

Seed RTT from valid selected-pair/RTCP/TWCC evidence and preserve its age. Zero/unknown/stale RTT must not masquerade as a zero-latency path. Give startup/unknown-RTT behavior an explicit bounded policy and test it at both LAN and high RTT. Do not hardcode a LAN deadline for all paths. Feedback that arrives after its usefulness deadline must not restart repair for an obsolete generation.

Coordinate one recovery episode per damaged dependency chain, allowing these bounded transitions rather than competing recovery storms:

1. Accept useful FEC reconstruction without delaying intact media to form a parity group.
2. Retransmit only when estimated arrival can still help the active decode chain.
3. Request recovery from an actually acknowledged valid reference when retransmission is unlikely to help.
4. Request a throttled keyframe when reference recovery is unavailable or fails; coalesce concurrent NACK/PLI/reference requests into one episode.

Deadline expiry is not permission to discard arbitrary encoded dependencies and resume with dependent P-frames. If the receiver cannot continue safely, establish an explicit recovery boundary and resume only from a decodable chain. Match recovery completion to actual decoded output and the active generation.

### Bound history and coordinate redundancy

The current 512-packet history covers very different time at 4 versus 100 Mbps. Size retained history from the useful time horizon and actual packet rate, with hard packet/byte ceilings. Initial design budget: at most 4,096 packets and 4 MiB retained packet payload per session, age-limited to at most the existing 250 ms; evict at the first bound. Account for metadata separately. Preserve bounded request queues and retry count. Publish hit, evicted, expired, and duplicate-repair counts so cap pressure is visible.

Charge parity, retransmission, probes, and control reserve to the same transport budget as video. FEC's existing 10%/20% policy becomes an explicit input to the shared allocator, not extra unaccounted traffic. Compare current group sizes against shorter groups for latency and burst tolerance. Keep parity generation/header reconstruction compatible with the native FlexFEC receivers. Add parity schemes only with actual negotiated receiver support and demonstrated benefit; no unnegotiated wire format.

If pre-decode WebRTC buffering still dominates recovery after sender changes, instrument the pinned receiver and introduce a narrowly scoped deadline/recovery patch. Keep H.264/HEVC and both clients interoperable. The exit criterion is shorter visible freezes, not higher NACK counts or a faster sender function.

### Required tests and exit gate

Use fake time for exact deadline edges, stale feedback, retry throttles, duplicate requests, packet/frame-ID wrap, generation switches, malformed feedback, history caps, and cancellation. Fuzz packet/history boundaries and recovery metadata; run affected Go tests under the race detector.

Run real native decode/presentation through seeded independent loss and bursts, with 5/20/50/100 ms RTT, feedback loss, reordering, bandwidth collapse, and FEC on/off. Include loss of keyframe fragments, reference acknowledgements, parity, and retransmission itself. Verify an owned input marker and key/button release during recovery. Old-frame ACKs, wrong epochs, invalid control grants, and expired sessions must not recover or control a different session.

Require lower visible-freeze distributions in moderate-loss cases, no corruption/stuck input, bounded overhead, and no recovery storm. High-RTT paths are compared with their own matched baseline; a universal sub-100 ms target is not physically meaningful.

## 4 — codec and content-aware bandwidth: P07–P08

Primary files: host `adaptation.go`, `fast_bitrate.go`, session configuration/capabilities; native capture configuration; both client codec negotiation/settings; CLI screen commands and screen documentation.

### Qualify codecs before changing Automatic

Build a hardware capability record for codec/profile/level, supported size/rate, actual encoder/decoder, startup success, recovery support, and measured performance class. An advertised codec name is insufficient. Keep H.264 available during negotiation and retain HEVC's current SDR Main/1080p60/40 Mbps scope in this release.

Automatic prefers HEVC only for qualified host/client combinations and workloads where matched-quality bandwidth savings meet the gate. Retain explicit H.264/HEVC choices. Unsupported 4K/120 requests continue through the supported H.264 path or existing explicit limits; do not silently shrink the requested mode just to claim HEVC savings.

At initial HEVC configuration/decode failure, perform one bounded H.264 renegotiation with a new media generation. Preserve authenticated session/control identity and correct input coordinate mapping. Authentication, permission, and network failures must retain their real error; they are not codec-fallback triggers. Mid-session codec changes require a controlled recovery boundary, with no old-generation pixels. Avoid periodic codec switching from short-lived content fluctuations.

Use source/decoded crops and settled frames to compare text readability, colored text edges, motion quality, and gradients. Include OCR/reading error and SSIM or another reproducible image metric; video-only quality scores cannot certify desktop text. Select bitrate by matched accepted quality, not by matching an encoder slider. Explicitly account for parity/repair/relay bytes.

### Replace fixed content cost with a bounded model

Use ScreenCaptureKit damage metadata when present, bounded sampled statistics, recent frame size/QP where available, motion/idle history, and recent interaction. Preserve zero-copy raw surfaces: no full-frame CPU readback to classify content. Missing damage metadata falls back to conservative behavior. Validate metadata semantics under scrolling, occlusion, display changes, and cursor-only movement before trusting it.

Implement an explicit controller state machine for idle, detail/reading, interaction, and sustained motion, respecting the existing Auto/Detail/Motion user setting:

- Idle: suppress redundant capture/encode work once quality is settled; allow bounded recovery/refinement/keepalive work. Separate cursor updates must not force video when the cursor is not embedded.
- Detail: preserve readable native pixels; reduce cadence before resolution where appropriate. After scrolling stops, send a bounded improvement frame if the settled text needs it.
- Interaction: prioritize fresh feedback and useful cadence with immediate bounded bitrate cuts on congestion.
- Motion: choose size/cadence from measured encode/decode/presentation costs and the current transport budget; do not force 60/120 fps that the device or path cannot sustain.

Allocate `total transport target = media + parity + expected repair/probe + control reserve`, using consistent byte units and protocol overhead estimates. Measure actual output to correct the estimate. The fast congestion loop owns rapid reductions; the content/geometry loop consumes that ceiling and owns slower quality/cadence changes. Use explicit hysteresis and minimum dwell times so the loops cannot fight. Recent input affects priority, not permission to exceed the user's bandwidth ceiling.

Document whether each existing bitrate field is a media ceiling or a transport estimate before exposing the allocator. Preserve the legacy field's semantics. If a user-configurable total-wire ceiling is added, give it a separate additive field with an explicit unset state, CLI flag/help, native controls, and route tests. Account for mandatory keepalives and startup/recovery transients separately from steady-state compliance; do not promise an exact instantaneous link cap from an encoder setting.

Use measured per-codec/size/device costs with conservative fallback instead of a universal bits-per-pixel constant. Feed pipeline age and achieved presentation cadence into overload decisions; `max(encode, send, decode)` alone does not describe the current serialized sender. Persist user choices normally, but keep device qualification data separate from secrets and transient feedback.

### Required tests and exit gate

Test deterministic content-state transitions, stale samples, missing metadata, odd dimensions, display changes, hysteresis, small budgets, capacity steps, and software-decoder overload. Verify a 20→4→20 Mbps path reduces load promptly without persistent packet queues and recovers without quality oscillation.

Run small text, colored code, scroll/stop/read, drag, noisy video, idle, and mixed scenes on both clients. Check CPU/power as well as wire bytes. No frozen stale tile/region, lost first interaction, unreadable settled text, or unexpected resolution change may pass simply because bytes fell.

Codec promotion target: at least 30% lower measured wire bytes at matched accepted quality, with no more than 5 ms p95 input-latency regression on the qualified workload/device class. This is an initial target to validate, not an assertion that HEVC always achieves it. Workloads failing it retain the qualified H.264 selection. Content-controller promotion requires savings in its intended workload and no material latency, readability, or cadence regression elsewhere.

## 5 — encoder burst control and useful overlap: P09–P10

Primary files: `native/macos-capture/DieterCapture.swift`, `NativeCaptureService.swift`, `SharedDisplayCapture.swift`, host `native_source.go`, `native_multiplexer.go`, `capture_pool.go`, `pacer.go`, and session media sending.

### Make encoder options observable and test their output

Centralize VideoToolbox option application and record status, accepted/read-back value where available, and fallback. Preserve required hardware encoding, real-time operation, and no frame reordering. Unsupported optional properties must not silently count as enabled.

The existing probe found several attractive flags rejected on this machine, including zero frame delay, small H.264 slices, and encoding-speed priority. Shorter rate windows and some QP settings were accepted individually, but encoded output was not tested. Do not infer portable support or a combined working configuration from those results.

Compare the current one-second rate cap against shorter burst windows with explicit headroom, measuring frame-size distribution, IDR size, frame drop, text quality, encoding duration, and downstream queue delay. A rate window is a cap, not a buffering delay. Test average target and hard cap together; an overly tight cap can cause undershoot or quality collapse. QP bounds and LTR settings remain capability-gated and measured. Avoid universal QP numbers.

Select a burst envelope that handles keyframes and recovery without producing a large bottleneck queue. Use the shared transport budget and observed queue, not only the encoder's nominal bitrate. Measure long-running rate compliance over multiple windows and startup/recovery bursts separately.

### Negotiate two stages, not an encoded FIFO

Retain the current single-credit path as the default compatibility fallback. Add a negotiated helper/daemon capability for bounded overlap; old helpers and old daemons stay on one credit. Do not change the interpretation of existing `frame_consumed` messages without a version/capability transition.

The new scheduler permits at most **one access unit being sent and one next frame being encoded or waiting to send**, with a single replaceable pending raw surface. It admits the second slot only when estimated encode plus remaining-send work fits the freshness deadline and resource budget. A larger credit count is not exposed as an unrestricted knob.

Define explicit states for raw pending, encoding, ready, sending, and retired; distinguish send-start admission from send-complete credit return. Each token binds rendition, helper incarnation, media generation, and frame ID. Duplicate, stale, unknown, or excess credits cannot create capacity. Reconfiguration, helper crash, cancellation, viewer removal, and recovery must retire tokens exactly once.

Bound encoded bytes as well as frame count. Start with a 4 MiB combined-payload admission target per rendition; this is a performance target, not an enforceable maximum for an encoder whose next output size is unknown. Reserve hard capacity before encoding: with the existing 16 MiB per-access-unit safety limit and two slots, the conservative payload ceiling is 32 MiB per rendition / 128 MiB across four renditions, before separately bounded copies. Lower that ceiling if the validated mode-specific access-unit limit permits it. If output exceeds the admission target, stop further overlap and drain/recover safely; do not truncate a valid frame or discard an arbitrary reference. Refuse oversize output through the explicit failure/recovery path. Finalize and test the complete allocation ledger before enabling overlap; GPU surface pools and parser/copy buffers need their own caps.

When congestion rises, stop admitting speculative work and fall back to one credit. Keep raw-frame replacement; do not replace an already encoded reference frame. Flush/discontinue encoded work only through an explicit generation/recovery transition. Resume overlap after sustained headroom, not on a single optimistic RTT sample.

Handle shared encoders deliberately: the fastest viewer's acknowledgement is not proof that all viewers consumed a frame. Preserve bounded per-viewer lag/discontinuity handling and isolate slow viewers. Do not share LTR state across clients with independent reference ownership. Exercise the shared native writer so one stalled rendition cannot block input/credits for all sessions beyond existing bounded deadlines.

### Tune pacing only after attribution

Parameterize pacing rate and burst duration in fixtures; compare 1×/1.5×/2.5× and bounded burst envelopes under actual bottleneck queues. Profile timers, allocations, locks, syscall count, and HEVC compressed-data copies. Optimize batching or reusable parsing only where profiles identify useful savings. Preserve final RTP/FEC headers, TWCC accounting, packet order where required, and control/repair fairness.

Verify final packet sizes after extensions, SRTP, and FEC on IPv4/IPv6/direct/TURN paths. Keep a conservative MTU; avoid assuming the existing packetizer setting alone guarantees no fragmentation. A faster socket write that creates a deeper downstream queue fails.

### Required tests and exit gate

- Model/fake-clock tests for credit conservation, admission prediction, byte caps, old-helper fallback, cancellation, blocked pipe, slow sender, recovery boundaries, and multiple renditions.
- Native hardware tests for actual overlapping timestamps, decoded reference correctness, combined burst/overlap behavior, and overload recovery at low and high bitrates.
- One/two/four viewers, with one intentionally slow viewer; mixed codecs and LTR capabilities; 1080p60, supported 1080p120, and H.264 4K60.
- Soak with capacity oscillation, periodic keyframes, helper failure/restart in the isolated fixture, sleep/wake, and display reconfiguration.

Enable overlap only where it measurably lowers frame age or improves sustained cadence without increasing tail input latency, loss, peak retained bytes beyond the declared bound, or quality regressions. Clean-loopback sending was not the dominant baseline cost; expect the benefit to depend on workload and path.

## Shared protocol, product, and resource requirements

For every slice:

- Keep session authentication, enrolled Ed25519 identity proof, DTLS binding, control generations, leases, clipboard generations, and decoded-reference validation intact. Trace/fallback/recovery code must never bypass them.
- Add proto fields with new numbers and explicit unknown/default behavior; preserve existing field meanings. Check old client/new daemon and new client/old daemon with actual pinned builds, plus malformed/unknown capability inputs. Do not enable a feature merely because an absent boolean decodes to false or a zero timestamp looks fresh.
- Native-client daemon operations require authoritative proto, explicit `grpcAPI`, thin Connect adapter, matching `internal/cli` local/direct-TLS/relay behavior, offline group/leaf help, help-contract tests, README/skill documentation, and `just proto`. Internal scheduling and local rendering preferences do not require invented RPCs.
- Keep product controls small: existing quality/codec choices, an understandable latency preference only where justified, actual applied settings, and actionable fallback reasons. Detailed encoder flags and research switches stay in diagnostics/fixtures.
- Preserve accessible controls, zoom/pan, text entry, pointer mapping, focus release, multi-display selection, and undocked Mac windows. Test clipboard transfer concurrently with loss and interaction; separate DataChannels still share transport capacity.
- Maintain a resource ledger covering pending/raw GPU surfaces, encode slots, encoded payload, retransmission packets/metadata, FEC groups, feedback/challenge queues, trace rings, and per-viewer state. Multiply by the four-viewer limit and verify allocation plateaus during soak. Frame-count bounds alone are insufficient.

Cursor shape caching and compressed HEVC-copy reduction can be included when profiling shows meaningful cost, with animated cursor/generation and decoder tests. Relative mouse input, unreliable key-state redesign, and shared LTR/temporal-layer encoders require separate protocol designs; they are not hidden prerequisites for this work.

## End-to-end qualification matrix

Every case verifies observable pixels and interaction, not just RPC success or frame arrival. Signaling route and media route are independent axes. A successful gateway connection does not prove TURN was exercised: assert the selected ICE candidate and relay protocol in the report.

| Suite | Mandatory cases | Assertions/artifacts |
|---|---|---|
| Authentication/routes | Loopback, verified direct TLS, isolated gateway relay; direct UDP, TURN-UDP, TURN-TCP/TLS fallback | Correct binding/candidate; denied/expired/revoked sessions fail; raw API stays local |
| Real desktop | Owned application click/type/scroll/drag, pointer/button release, small text, resize, display switch | Marker identity at presentation; correct coordinates; no stuck input or stale generation |
| Presentation | Mac 60/120 Hz where supported, immediate/synchronized/unsynchronized experiments; Android texture/direct surface | Actual endpoint named; cadence/age/tearing; idle and first-frame behavior |
| Codec | H.264; HEVC qualified/unsupported/failed startup; forced software H.264 fallback | Actual implementation; bounded retry; correct fallback reason; no black-screen loop |
| Network | Low-RTT LAN, Wi-Fi, 20/50/100 ms RTT; 0/0.1/0.5/1/3% random loss; multi-packet bursts; reordering/jitter; asymmetric feedback loss | Visible-freeze and input distributions; FEC/NACK/LTR/IDR correctness; bounded repair bytes |
| Capacity | Fixed 4/8/20 Mbps and 20→4→20 Mbps, with a known bottleneck queue | Wire budget, convergence, no persistent queue or quality oscillation |
| Content | Idle, cursor-only, grayscale/colored text, scroll-stop-read, window drag, animation, photographic/noisy motion | Readability/quality crops; matched-quality byte savings; resume latency |
| Modes | 1080p60 baseline, actual Retina viewport, H.264 4K60, supported H.264 1080p120 | Achieved cadence and geometry; no unsupported HEVC claim |
| Concurrency | 1/2/4 viewers, fast plus slow viewer, mixed clients/codecs, control handoff, concurrent clipboard | Independent progress/references; bounded memory and aggregate egress; correct ownership |
| Lifecycle | Undock/redock, surface destroy/recreate, foreground/background, lock/unlock, sleep/wake, signaling interruption, helper failure, lease expiry, disconnect during encode/send/present | No stale pixels, leaked codec/surface/helper, stuck input, or resurrected session |
| Compatibility | Previous released client/daemon both directions; old helper; unknown optional fields/features | Conservative fallback; actionable unsupported cases; no protocol deadlock |
| Sustained operation | 60-minute motion/thermal, 60-minute constrained/lossy path, 60-minute mixed-viewer churn on qualified platforms | Stable resource plateau; latency/cadence over time; no crash/hang/recovery storm |

Do not run the full Cartesian product. Run all correctness cases with deterministic fixtures; a pairwise physical matrix covering every axis; and the mandatory high-risk combinations: HEVC + reference recovery + burst loss, Android surface recreation during codec fallback, Mac resize during delayed presentation, overlap + capacity collapse + four viewers, and clipboard/input under TURN-TCP loss. If a failure reveals an interaction, add that exact combination as a permanent regression case.

### Automated and physical validation layers

1. **Every affected patch:** pure state machines, protocol compatibility, boundedness, race/fuzz checks where appropriate, and meaningful component tests. Avoid tests that merely duplicate setter calls.
2. **Native integration:** existing signed helper, real hardware encoder, native decoders, and deterministic owned pixels; real application input for presentation/latency changes.
3. **Emulator journeys:** UI, session lifecycle, gestures, fallback, control ownership. No emulator performance claims.
4. **Physical qualification:** two Macs with different performance/display characteristics, physical Android codec families, isolated network impairment, actual TURN and remote routes.
5. **Optical and competitor comparison:** matched display modes/content/quality, same network, same input marker, at least three runs; record Parsec and Sunshine/Moonlight versions/settings and actual bandwidth. Compare full input-to-photon with full input-to-photon, not a competitor overlay's encode-only metric. Report unavailable platform/mode combinations explicitly.

P00 adds proposed runner interfaces for performance collection and comparison, with names finalized in implementation. They must accept a pinned baseline, scenario manifest, exact device/fixture identity, evidence directory, and required-case list. They produce machine-readable results and a short human report. They are **new work**, not commands available today.

Existing repository entry points remain:

```sh
just check-changed --dry-run
just check-changed
just mac screens-native-test
DIETER_TEST_SCREEN_CAPTURE_REAL=1 DIETER_TEST_SCREEN_LATENCY_ONLY=1 just mac screens-test
DIETER_TEST_SCREEN_LATENCY_ONLY=1 just mac screens-test
DIETER_TEST_SCREEN_LATENCY_MATRIX=1 just mac screens-test
DIETER_TEST_SCREEN_RECOVERY=1 just mac screens-test
just android test
just android screens-test
DIETER_SCREEN_TEST_SOURCE=screen just android screens-test
DIETER_SCREEN_TEST_MULTI=1 just android screens-test
```

Run the affected checks selected by the repository planner and inspect native reports. Use the existing Android codec/recovery instrumentation classes via `DIETER_SCREEN_TEST_CLASS`; confirm the runner's exact interface when implementing rather than assuming a new shorthand. Full repository-wide checks are for CI or an explicit full-validation request; do not claim unrelated shared working-tree changes have passed unless their checks actually ran.

Before native tests, inventory with the Mac/Android skill commands. Keep canonical Swift caches; serialize users of the same cache. Preserve the pinned emulator/JBR and exact ADB serial. Fixtures use temporary `DIETER_HOME`, random loopback listeners, disposable identities, and exact PID/port cleanup. Never stop, replace, or install over the operator daemon, kill an operator app to make a test run, clear device data, or change global networking. Record an unavailable integration run and arrange a dedicated test environment.

## Acceptance criteria and default promotion

Separate hard correctness gates from performance objectives. Required correctness/resource/security/lifecycle cases must all pass; missing hardware is **unavailable**, not a waiver or green result. A feature can merge behind its default-off switch while qualification is pending, but the overall work is not fully E2E-qualified until the mandatory cells run.

| Area | Initial performance objective | Promotion rule |
|---|---|---|
| Mac clean LAN | 1080p60, RTT <5 ms: input-to-presentation p50 ≤40 ms, p95 ≤60 ms | Controlled baseline first; repeatable gain in the stage being changed, no unexplained >5 ms p95 input regression or cadence loss in qualified cells |
| Android | Lower full input latency and/or power on qualified physical devices | Decoder-setting/surface gain survives the full pipeline; fallback and lifecycle pass; do not prescribe one millisecond target across all phones |
| Recovery | Low-RTT moderate-loss p95 visible recovery <100 ms as the initial target | Matched baseline improves materially; high RTT has a separately achievable budget; no corruption, retry storm, or unacceptable overhead |
| Codec | ≥30% wire savings at matched accepted quality | ≤5 ms p95 input regression; no hidden size/FPS reduction; only promote qualifying combinations |
| Adaptation | Rapid load reduction on a capacity collapse; stable recovery | Initial deadline target: within max(300 ms, 3×fresh RTT + 100 ms) after observable congestion; validate against fixture queue/feedback behavior before freezing the contract |
| Overlap/bursts | Lower frame age or higher sustained cadence in constrained sender cases | No worsening of tail latency, quality, fairness, or declared memory bounds; otherwise retain one-credit mode |
| Idle | No repeated video work after settling absent damage/recovery/refinement | Account for control/ICE traffic separately; first interaction meets its latency budget |

These are proposed targets, not measured results or brittle timing assertions for shared CI. Freeze scenario-specific thresholds after P00, before evaluating optimization candidates. Any later threshold change requires written evidence and review; do not move it just to turn a failing run green. For sustained motion, compare late/missing presentation rate with baseline and require achieved cadence appropriate to the selected mode. For power/CPU, flag more than 10% sustained regression for explicit review even when latency improves.

Use a staged rollout:

1. Default-off disposable fixture switches, one variable at a time.
2. Combined opt-in mode with complete diagnostics and immediate fallback.
3. Defaults for qualified codec/device/display classes only; conservative behavior for unknown combinations.
4. Broader qualification based on repeatable evidence. A startup failure disables only the failing optional feature for that session/device policy; avoid recursive reconnect/reconfigure loops.

Keep independent rollback controls for Mac presentation policy, Android low-latency options, Android surface output, recovery policy, automatic HEVC preference, content adaptation, burst envelope, and overlap. Rollback must preserve active session correctness; changes needing codec/helper reinitialization use an explicit generation boundary. No testing or rollout step authorizes restarting the operator's daemon.

## Definition of complete

The work is complete only when all of the following are reviewable:

- P00–P11 changes are implemented and tested, with rejected experiments and retained fallbacks documented.
- Both native clients and the host pass the mandatory correctness, route, compatibility, lifecycle, and resource tests; physical qualification covers the enabled defaults.
- A baseline-versus-final report contains aligned latency, visible freezes, matched-quality wire bytes, cadence, CPU/power, and soak memory results, including unsuccessful cases and uncertainty.
- Parsec/Moonlight comparisons use matched end-to-end measurements; any claim of comparable performance identifies the tested hardware, content, quality, and route.
- Proto/generated clients, daemon API, CLI/help/skill parity, and supported-mode documentation agree. Correct the public screen guide's outdated FFmpeg/single-viewer claims and document actual codec, mode, fallback, and route behavior.
- Default selection and rollback are explicit, artifact builds are reproducible, and the operator environment is unchanged by the test workflow.
- The release report lists exact executed/passed/failed/skipped/unavailable counts and evidence paths. No required unavailable cell is described as end-to-end tested.

The first implementation step is P00 followed immediately by P01/P02: establish aligned presentation evidence, fix ownership accounting, and select the Mac presentation policy. This addresses the largest measured delay while supplying the measurement contract needed to finish the other four priorities safely.

## Technical references

The investigation contains repository evidence and the September 18 measurements. Primary external references supporting the candidate mechanisms are Apple's [VideoToolbox low-latency design](https://developer.apple.com/videos/play/wwdc2021/10158/), [Metal display synchronization](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled), and [capture damage metadata](https://developer.apple.com/documentation/screencapturekit/scstreamframeinfo/dirtyrects); Android's [low-latency decoder support](https://developer.android.com/about/versions/11/features) and [surface tradeoffs](https://developer.android.com/media/media3/ui/surface); Moonlight's [Android decoder implementation](https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java); and Sunshine's [configuration](https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html). These establish available techniques, not performance guarantees for Dieter.
