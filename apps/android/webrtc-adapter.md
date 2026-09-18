# Screen decoder adapter contract

Dieter pins `io.github.webrtc-sdk:android:150.7871.01`, SHA-256
`0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0`.
`preBuild` verifies the resolved upstream AAR. `buildScreenWebRTC` builds the
[Java SDK extension](../../native/android-webrtc/README.md) while verifying all
four native JNI libraries remain byte-for-byte unchanged. Generated provenance
records exact compiler/source/input/output hashes. Do not update this pin without recompiling
and exercising the adapter, normal texture callbacks, codec fallback, reference
acknowledgements and actual physical decoding.

`org.webrtc.DieterLowLatencyDecoderFactory` is original Dieter code compiled in
the SDK's Java package. M150 already exposes the required package-private
`AndroidVideoDecoder(MediaCodecWrapperFactory, String, VideoCodecMimeType, int,
EglBase.Context)` constructor. The selected codec's implementation name is its
MediaCodec name. Its constructor allocates no codec; `initDecode` owns allocation.
The low-latency adapter needs no reflection or duplicate runtime classes.
The surface extension adds an overload to that constructor. Its SDK classes are
rebuilt from the recorded upstream source revision, preserving upstream BSD
notices and patent grant; the native library and JNI signatures remain unchanged.

On API 30+, the selected codec must advertise `FEATURE_LowLatency` before the
adapter requests `KEY_LOW_LATENCY=1`. Configuration or start rejection releases that
codec and retries exactly once with a fresh ordinary codec. Acceptance does not
prove reduced latency. Missing support, software decoding and rejected settings
are explicit diagnostics. The production default remains off until an advertising
physical codec passes latency and lifecycle qualification; fixtures opt in explicitly.
H.264 platform fallback and HEVC hardware admission
retain the existing behavior.

Reproduce with `just android test`, then run the physical fixture using
`scripts/test-android-screens-device.sh SERIAL`. For codec journeys set
`DIETER_SCREEN_TEST_CLASS=com.dbpprt.dieter.screens.ScreenCodecEndToEndTest`.
The app ID is `com.dbpprt.dieter.screenfixture`, separate from the operator app.
Use `DIETER_SCREEN_TEST_LOW_LATENCY=0` for the baseline and
`DIETER_SCREEN_TEST_SURFACE=1` for the SurfaceView/EGL experiment.
The ordinary `just android screens-test` retains its emulator-only guard.

Fake-codec instrumentation class `org.webrtc.DieterLowLatencyCodecTest` verifies
configuration acceptance, one-time recreation, removal of the optional key and
second-failure propagation. Run `connectedScreenFixtureAndroidTest` with
`-Pdieter.screenTestBuildType=screenFixture`, the exact `ANDROID_SERIAL`, and the
class instrumentation filter. No daemon fixture is needed for this class.

`DIETER_SCREEN_TEST_DIRECT_SURFACE=1` selects the separate direct MediaCodec
path. An SDK-private `MediaCodecSurfaceFrame` owns a real dequeued output index,
not placeholder pixels. The existing JNI bridge retains that actual buffer for
normal RTP timestamp matching, decode statistics and reference acknowledgements.
The surface-aware sink releases it once to the borrowed SurfaceHolder surface.
Direct rendering supplies the current monotonic timestamp explicitly; the
boolean overload's media-PTS timestamp is unsuitable for SurfaceView scheduling.
The callback keeps media PTS for frame identity and validates render time against
the local release/callback interval. Invalid clocks cannot become zero latency.
At most two decoded output buffers and 32 pending render-callback records are
retained; the UI keeps one latest frame awaiting its canvas transform.

The direct path uses fixed decoder-sized storage with compositor zoom/pan and
parent-view cursor composition. Closing the holder generation fences late
outputs/callbacks and stops its decoder; closed/unavailable targets and initial
configuration failures fall back to ordinary textures. The original TextureView
and optional SurfaceView/EGL paths still use shared textures. SurfaceView/EGL
alone is **not direct MediaCodec output**.

Feedback distinguishes `ANDROID_FRAME_RENDERED` from `EGL_SUBMITTED`.
MediaCodec callbacks may be delayed/batched; neither endpoint means physical
scanout. Tests require native `framesDecoded` to advance and reference ACKs only
after actual output. Direct output, low-latency configuration and SurfaceView/EGL
remain fixture-only pending physical latency/power/device qualification.

Actual MediaCodec output dequeue is also observed before a busy texture consumer
may discard an already decoded frame. Reference ACKs deduplicate this identity
against the ordinary frame callback (which also covers software fallback).
Recovery instrumentation observes this real decode endpoint independently of
rendering; it still requires the exact RTP timestamp of the dropped protected
packet. No compressed-input or fabricated-frame callback satisfies that proof.
