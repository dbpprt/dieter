> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Hardware HEVC screen sharing

The initial HEVC path is implemented as an opt-in feature. H.264 remains the
native-client default until the matched-quality bandwidth and presentation
latency gates in the [plan](screenshare-hevc-plan-2026-09-17.md) pass.

## Behavior

- Mac and Android screen options expose Automatic, H.264, and strict HEVC.
  The codec menu remains available after a failed connection so the user can
  restore H.264. The CLI accepts `screen start --codec auto|h264|hevc` and
  preserves the request's JSON preference when the flag is omitted.
- The first HEVC mode is Main, SDR, 8-bit 4:2:0, up to 1920×1080/60 fps.
  The host advertises codec-specific hardware modes. An incompatible offer,
  missing hardware capability, or larger requested mode keeps Automatic on
  H.264. Strict HEVC reports an error. The existing H.264 modes remain available.
- Codec changes create a new authenticated session. The signed offer/answer
  binding, input release, decoder/render generation reset, and bounded resource
  teardown remain in the connection path.
- Automatic retries H.264 once after a native HEVC initialization failure or
  complete received frames that cannot produce the first decoded frame. The
  H.264 decision survives transient reconnects. Permission, trust, authentication,
  and ordinary network errors do not activate this codec downgrade.
- Capture variants include codec in both creation and reconfiguration identity.
  H.264 and HEVC viewers share the capture service but use separate encoders.
  The existing four-viewer/variant bounds remain enforced.

## Native implementation

VideoToolbox requires hardware encoding, uses HEVC Main with real-time operation
and no frame reordering, and supplies Annex B VPS/SPS/PPS with random-access
frames. HEVC uses Pion's RFC 7798 payloader. Existing pacing, NACK/PLI, encrypted
media, frame credits, and latest-frame capture behavior are retained.

The pinned Mac M151 framework has HEVC RTP support but its default Objective-C
decoder factory does not expose HEVC. A small RTCVideoDecoder adapter now uses
hardware-required VideoToolbox decoding into native NV12 surfaces. Its bounded
Annex B parser rejects malformed headers, oversized parameter sets, and excess
NAL units. Decode is synchronous with frame timestamps preserved, then the
existing Metal path receives the decoded surface directly. Apple's synchronous
decode behavior is documented in [VTDecodeFrameFlags](https://developer.apple.com/documentation/videotoolbox/vtdecodeframeflags/kvtdecodeframe_enableasynchronousdecompression).

The HEVC encoder rejected `MaxFrameDelayCount` with status -12900 on this Mac.
It is not set for HEVC. Frame reordering is disabled and the existing single
frame credit bounds outstanding encoder work. The H.264-only low-latency rate
control specification is also omitted for HEVC.

Android's pinned 150.7871.01 SDK supports HEVC RTP and MediaCodec. HEVC uses only
the hardware decoder factory, filtered for Main profile, sufficient level, and
1080p60 size/rate support. Android versions before API 29 retain H.264 because
the hardware/software classification cannot be verified through that API.
Software HEVC is not used as a hidden fallback. Output retains shared EGL
surfaces and immediate presentation.

## Validation on this machine

- Go affected-package race tests and vet passed, including local, verified
  direct-TLS, and authenticated relay CLI operation. Strict HEVC rejects the
  unsupported fixture over all routes; an explicit Automatic override works.
- Native helper suite passed. A dedicated 120-frame 1080p60 HEVC test passed
  RTP fragmentation/reassembly and parameter-set verification. Observed encoder
  time was approximately 3.5–4 ms per frame at 60 fps on Apple M4. These are
  simple synthetic frames, not a matched-quality bandwidth benchmark.
- Mixed H.264/HEVC native viewers passed simultaneous streaming, resizing, and
  reconfiguration without merging encoders across codecs.
- All 617 Mac unit tests passed. Four additional HEVC checks ran with real
  fixtures: parser rejection, opt-in admission, 120 hardware-decoded frames plus
  lost-reference recovery, and an authenticated Go-server-to-native-WebRTC
  HEVC connection producing native 1920×1080 surfaces. These tests open no app
  window and use no operator daemon.
- All 299 Android unit tests passed; debug APK assembly passed. The visible
  `Pixel_9_API_37_1` / `emulator-5554` codec test passed H.264 → Automatic HEVC,
  injected decoder failure → H.264, retention across reconnect, strict HEVC,
  rejection of strict HEVC at 120 fps, and switching back through the UI.
  The emulator reports `c2.goldfish.hevc.decoder` as hardware accelerated;
  this establishes functionality, not physical Android performance.

One full repository check hit `TestGatewayEnrollsDaemonAndRelaysDieterService`
at its projection-neutral synchronization assertion. Its isolated race-test
rerun and the subsequent full Go race-test run passed without a gateway code
change. This is recorded separately from codec validation.

The broad Android screen journey reached streaming video and control but failed
at `ScreenEndToEndTest.kt`'s clipboard-copy assertion with `clipboard is busy`.
That clipboard work was already present in the shared working tree. It is not
covered up by the dedicated codec test.

The final `just check-changed` run passed generation, Go race tests, vet, and
the native helper suite, then stopped at the Mac presentation/input guard.
Later checks in that runner were not reached; Mac and Android unit/codec checks
were run separately as listed above.

The Mac presentation/input integration command refuses to run beside the
operator's `/Applications/Dieter.app` process. That app and the running daemon
were left untouched. The task-owned emulator was closed through the normal
snapshot-saving shutdown, and the physical phone was not used. The shared-tree Swift format check also reports existing
clipboard-source formatting; the HEVC Swift files pass formatting.

Evidence from this run is in `/tmp/dieter-hevc-mac-proof.log`,
`/tmp/dieter-hevc-mixed.log`, `/tmp/dieter-hevc-android-codec.log`,
`/tmp/dieter-hevc-mac-all.log`, and `/tmp/dieter-hevc-check-final.log`.
Android HEVC and H.264 screenshots are in
`/tmp/dieter-android-screens.o9jI9r/`.

## Reproduce

```sh
# Isolated hardware encoder/RTP/native decoder proof, no GUI or live daemon.
native/macos-capture/test-hevc.sh

# Visible emulator; no physical phone is selected.
just android emulator-start
DIETER_SCREEN_TEST_CLASS=com.dbpprt.dieter.screens.ScreenCodecEndToEndTest just android screens-test
just android emulator-stop

just check-changed --dry-run
just check-changed
```

## Gates before changing the default

Still required: replay text, scrolling, UI animation, and video content at
4/6/8/12 Mbps, compare matched visual quality and actual wire bytes including
retries/probes, and measure median/p95 input-to-presentation latency across
three runs per network condition. Validate physical Android hardware and power
use, plus sleep/wake and loss behavior with real presentation. The plan's
30% bandwidth saving and no more than 5 ms latency regression remain targets,
not measured results. HEVC is not promoted to the native default, 4K, 120 fps,
HDR, or 4:4:4 by this change.
