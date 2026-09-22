> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Hardware HEVC screen-sharing plan

Status: the opt-in 1080p60 implementation and native interoperability checks are complete. See [implementation and validation](screenshare-hevc-implementation-2026-09-17.md). Matched-quality bandwidth, real presentation latency, and physical Android performance gates remain open; H.264 stays the default.

## Objective and initial scope

Reduce actual screen-stream bandwidth at matched visual quality while retaining the latency, input, recovery, and compatibility of the existing H.264 path. The initial proof is SDR, 8-bit, 4:2:0 HEVC Main at 1920×1080 and 60 fps. Expand to the existing 4K60 and 1080p120 operating modes only after each is validated. HDR, 4:4:4, AV1, FEC, and a transport replacement are separate work.

Proposed promotion targets, not promised results:

- At least 30% fewer wire bytes on the agreed active desktop workload at matched quality; report idle and individual workloads separately.
- Input-to-presentation median and p95 no more than 5 ms worse than the same-run H.264 baseline across repeated measurements.
- Hardware encoding and decoding verified at runtime, with no silent software HEVC fallback.
- All existing H.264 connection, control, clipboard, mixed-version, and recovery checks remain passing.

## Repository findings before implementation

- Native capture hardcodes H.264 session creation, profile selection, capability reporting, and parameter-set extraction in `native/macos-capture/DieterCapture.swift`.
- Go hardcodes H.264 native source identity and packetization. The pinned Pion WebRTC v4.2.18 and RTP v1.10.5 already contain H.265 support, including an H.265 payloader; Dieter still needs correct integration and interoperability tests.
- Mac uses WebRTC M151 and Android uses webrtc-sdk 150.7871.01. Both client factories and transceiver preferences filter to H.264. The Android archive contains HEVC identifiers, but that is not proof of usable hardware decoding or RTP interoperability. Mac runtime HEVC support is unverified.
- Capture variants currently match stream configuration and profile. Codec must join that identity to keep simultaneous H.264 and HEVC viewers isolated while sharing capture where possible.
- Capabilities already expose a codec list and session state already exposes the selected codec. Explicit preference and codec-specific support/limits need an additive contract.
- Existing clipboard/recovery work is present in the working tree. Implementation must integrate with it and preserve changes owned by other tasks.

## 1. Prove feasibility with the pinned dependencies

Build a disposable native probe before changing production defaults:

1. Create a hardware-required VideoToolbox HEVC Main session, encode moving NV12 test pixels, and confirm actual hardware use. Probe supported properties rather than copying H.264-only low-latency settings into HEVC.
2. Query the bundled Mac and Android decoder factories and their actual codec/profile capabilities. Confirm that their RTP receive paths can negotiate and deliver HEVC frames.
3. Decode the fixture through each native client and present it with the current Metal/EGL path. Check pixel output, codec identity, frame cadence, and decode time.
4. If a wrapper is missing but RTP support exists, implement a small hardware decoder adapter. If the bundled libwebrtc lacks required RTP support, resolve a reproducible dependency update/build first; advertising an invented codec name is insufficient.

Exit: a documented host/client capability matrix and a working 1080p60 hardware HEVC round trip. The emulator can establish functionality, not physical Android hardware latency. Unsupported devices retain H.264.

## 2. Define negotiation and fallback

- Add `auto`, `h264`, and `hevc` preference to the start request. Zero/default preserves legacy behavior during the opt-in rollout. Use existing capability/state fields where sufficient and additive codec-specific mode/profile metadata where needed; allocate field numbers from the current schema at implementation time.
- `auto` selects HEVC only when the host, the real client decoder, and the offered profile/mode all qualify. Otherwise select H.264 without reducing the requested resolution solely to obtain HEVC.
- `h264` is a compatibility override. Explicit `hevc` is strict for diagnostics and benchmarks: unsupported mode or codec produces a useful error instead of concealing a failed HEVC experiment with H.264.
- Codec is fixed for a negotiated peer session. A preference change reconnects the viewer with a fresh authenticated offer/answer; it is not an ordinary live bitrate configuration update.
- In auto mode, a codec-specific initialization or first-frame decode failure permits one HEVC-to-H.264 retry. Release input and invalidate old decoder/render generations before retrying. Keep that tab on H.264 through transient reconnects until an explicit retry or a new tab, preventing codec oscillation.
- Trust, authentication, permission, or general network failures must not be misclassified as codec failures. Preserve current recovery semantics for those cases.
- Parse SDP structurally, validate HEVC profile/tier/level and payload mappings, and preserve the existing signed SDP binding. Test new/old host and client combinations.

Exit: a deterministic negotiation/fallback test matrix, including invalid offers, unsupported hardware, and strict HEVC failure.

## 3. Implement the host and media path

- Carry codec through `SourceOptions`, native helper commands, source identity, encoder variants, and state reporting. Missing codec fields mean H.264 for compatibility.
- Add hardware HEVC creation with real-time operation and no frame reordering. Validate supported low-delay properties and observed output delay. Keep the existing bounded encoder admission and raw-frame replacement policy.
- Extract HEVC VPS/SPS/PPS and convert encoded output to Annex B safely. Handle random-access frames, parameter changes, display switches, and restart boundaries without reusing H.264 NAL parsing.
- Select the matching RTP payloader and negotiated parameters. Exercise HEVC fragmentation, parameter-set delivery, marker bits, timestamps, NACK/PLI, and recovery under packet loss using the existing encrypted transport.
- Include codec/profile/mode in shared-encoder matching. Preserve encoder limits and ensure a slow or incompatible viewer cannot stall or downgrade another viewer. Admission failure must release partial resources.
- Keep frame-size, payload, queue, and decoder-input limits in place, with malformed/truncated HEVC tests.

Primary files: `source.go`, `native_source.go`, `native_multiplexer.go`, `capture_pool.go`, `manager.go`, `session_configuration.go`, `CaptureProtocol.swift`, and `DieterCapture.swift`.

Exit: hardware host tests and Go media/negotiation/recovery tests pass for both codecs, including mixed-codec viewers.

## 4. Integrate native clients and CLI

- Mac: advertise only usable HEVC modes, retain H.264 alternatives, and feed decoded native surfaces directly to the existing generation-bound Metal renderer.
- Android: require a suitable hardware MediaCodec decoder for HEVC, preserve EGL texture output, and exclude software HEVC from automatic selection. A failed hardware decoder activates the defined fallback policy.
- Expose Automatic and H.264 compatibility choices in normal screen options, with selected codec and fallback reason visible in stream diagnostics. Keep forced HEVC available for explicit testing/advanced selection.
- Add `dieter screen start --codec auto|h264|hevc`; report selected codec through existing status/watch output. Explain that changing codec requires a new session rather than adding a misleading live-configure flag.
- Implement additive schema handling explicitly in `grpcAPI`, retaining the thin Connect adapter. Update root/leaf help, CLI contracts and operation tests, README, and the Dieter CLI skill. Run `just proto` for generated Go, copied schemas, and checked-in Swift clients.
- Verify CLI start/negotiation through loopback, verified direct TLS, and authenticated relay. These are signaling routes; media-path testing separately verifies ICE/direct media and TURN when a fixture is available.

Exit: both native client journeys and CLI route tests pass, including reconnect, mixed versions, and explicit H.264 operation.

## 5. Tune and benchmark actual savings

Do not equate a lower configured bitrate ceiling with lower bandwidth at equal quality. Do not assume the H.264 quality controller's bitrate-per-pixel estimates apply unchanged to HEVC.

- Use repeatable typing, syntax-colored text, scrolling, window movement, and video workloads. Capture reference frames and verify decoded text, edges, color, and motion; combine aligned image metrics with visual/OCR checks.
- Sweep H.264 and HEVC bitrate limits, initially 4/6/8/12 Mbps at 1080p60. Find matched-quality pairs, then repeat the selected pairs at least three times under comparable machine load.
- Measure media bytes and total wire bytes including retransmissions/probes, encode/decode distributions, actual presentation cadence, input-to-presentation median/p95, dropped frames, first-frame time, CPU/GPU load, and memory.
- Tune codec-specific rate estimates from measured frame sizes and quality results. Keep explicit bitrate settings as upper bounds and preserve congestion safety.
- Run clean LAN and constrained-network cases, including jitter, loss, and sudden bandwidth reduction. Keep one-machine monotonic timing separate from two-machine timing; use clock alignment or an external measurement for cross-machine end-to-end claims.
- Run native hardware Android measurements only on an available, explicitly authorized test device. Do not treat emulator throughput as physical-device evidence.

Exit: the promotion targets are met for supported configurations, or HEVC stays opt-in with the measured tradeoff recorded. No blanket “half the bandwidth” claim.

## 6. Regression, rollout, and rollback

- Cover helper termination, peer loss, display/resolution changes, sleep/wake, fallback races, concurrent H.264/HEVC viewers, control handoff, clipboard activity, and explicit disconnect. Verify bounded sessions, encoders, queues, and retry state during soak testing.
- Run `just check-changed --dry-run`, then `just check-changed`, plus the focused synthetic/real screen fixtures for both codecs. Preserve and report unrelated failures independently.
- Use disposable `DIETER_HOME` roots, ports, identities, and input windows. Never restart/install over an operator daemon or app; preserve physical-device and emulator lifecycle rules.
- Land as reviewable increments: feasibility evidence; host/contract/transport; native clients/CLI/fallback; benchmark tuning/default selection. Keep H.264 as the shipped default until the promotion gates pass. Then enable HEVC preference only in validated hardware/mode combinations.
- Rollback is selecting H.264 and reconnecting; no data migration or transport replacement is required.

## References

- [HEVC RTP payload format and SDP negotiation, RFC 7798](https://www.rfc-editor.org/rfc/rfc7798)
- [Apple VideoToolbox hardware decode capability](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:))
- [Apple low-latency VideoToolbox design](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [Parsec codec support and its reported HEVC bandwidth benefit](https://support.parsec.app/hc/en-us/articles/32381568346644-Hardware-and-Software-Compatibility)
- [Dieter's existing latency measurements](screenshare-latency-2026-09-17.md)
