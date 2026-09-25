# Android decoder surface extension

The input dependency is `io.github.webrtc-sdk:android:150.7871.01`, SHA-256
`0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0`.
Its distribution identifies source commit
[`73cb8180f7258ee292878d6edd05177f41883962`](https://github.com/webrtc-sdk/webrtc/commit/73cb8180f7258ee292878d6edd05177f41883962).
`upstream.json` records original source hashes; `java/` contains four modified
upstream files and two original extension files. Upstream BSD notices and patent
grant are retained. A dependency upgrade requires an explicit source/ABI audit.

## Build and provenance

Android's `buildScreenWebRTC` task verifies the upstream AAR, compiles these Java
sources, and replaces each corresponding class and its nested classes exactly
once in the AAR. It preserves every original JNI library, manifest and other
resource. Derivative BSD/patent notices also enter the JAR resources. No Java reflection, alternate class loader, duplicate runtime classes,
new JNI symbol, or native-library substitution is involved. The existing native
`AndroidVideoBuffer` retains the real Java buffer through the normal JNI bridge.

The builder is `build_sdk.py`. It uses the Gradle JDK's `javac --release 8`, the
configured Android platform JAR and pinned annotation JAR. Outputs live under
`apps/android/app/build/screen-webrtc/`: `dieter-webrtc.aar` and provenance JSON.
Provenance contains compiler version, every extension source hash, builder hash,
input/output AAR hashes and all four native-library hashes. ZIP ordering and
timestamps are deterministic. Rebuilding with the same compiler and inputs must
produce the same AAR; compiler changes intentionally change provenance. This is
a Java SDK rebuild, not a claim of rebuilding native WebRTC from source.

Run `just android test` to build the normal application against this contract.
No Linux VM is necessary for this extension because native JNI signatures and
implementations are unchanged. Source investigation did verify a separate Linux
builder, but its dependency synchronization is not release-build evidence.

## Output ownership

`DecoderSurface` borrows one SurfaceHolder generation. The owner closes it before
returning from `surfaceDestroyed`; the SDK never releases the holder's Surface.
Configuration/start is atomic with invalidation. Closing fences submissions,
stops the attached decoder and invalidates delayed render callbacks. Decoder
shutdown retains the original five-second timeout; a timed-out worker retains
its own codec state and cannot be reinitialized in place.

`MediaCodecSurfaceFrame` can only be constructed inside the SDK after a real
successful output dequeue. It owns the exact output index, dimensions and
MediaCodec presentation timestamp. The ordinary decoded-frame callback still
updates native RTP matching and decode statistics. A separate output-dequeue
hook reports media identity before a busy texture consumer may discard the
already decoded output. Reference ACKs and FEC proof use actual decoder output;
software fallback retains the ordinary frame callback. Neither hook counts as
presentation, and compressed input admission never acknowledges decoding.

The surface-aware sink can render that actual buffer once, discard it, or retain
it briefly. Object identity fences reused indices; closing/reinitializing the
decoder retires old ownership. At most two unreleased decoded outputs and 32
render-callback records are retained. This bounds the extension's queue,
not hidden vendor codec/SurfaceFlinger buffering. MediaCodec receives timed
releases with the current `System.nanoTime()`, never a future frame queue.
The boolean render overload inherits media PTS as the surface timestamp; RTP
media time must not be mistaken for Android system time. This distinction is
specified by [MediaCodec's surface contract](https://developer.android.com/reference/android/media/MediaCodec#releaseOutputBuffer(int,%20long)).
Render callbacks outside the local release-to-callback interval are rejected
instead of producing fabricated zero or cross-clock latency.

`VideoFrame.SurfaceBuffer` is explicitly receive-only and opaque. It cannot be
forwarded to generic I420 sinks/encoders; `toI420()` returns null. This is the
storage contract for an actual surface-mode output index, not a placeholder
image. Dieter's existing texture path remains the path for pixel conversion and
unsupported composition. A closed/unavailable optional surface or initial
configuration rejection selects ordinary shared-texture output.

Canvas zoom/pan changes the SurfaceView's compositor geometry while its buffer
stays decoder-sized. Cursor and controls stay in the parent view. A cover hides
old pixels until a valid current-session frame-render callback. The canvas keeps
one latest output waiting for the UI transform. Normal texture/EGL remains the
production presentation default.

## Evidence and qualification

The isolated physical runner accepts `DIETER_SCREEN_TEST_DIRECT_SURFACE=1`.
Run `just e2e run --suite sdk --serial SERIAL` for the bounded
codec/ownership checks and launcher-namespace regression in the separate fixture
application. It acquires the shared device lease, requires all selected tests
to execute without skips, and emits `decoder-sdk.json` from fresh JUnit results.
The qualification manifest includes this as the required `android-sdk` case.
`org.webrtc.DieterSurfaceOutputTest` tests bounded ownership, index reuse, late
release/callbacks, SurfaceHolder ownership, opaque format handling and failed
worker reinitialization. `ScreenCodecEndToEndTest` requires real H.264/HEVC
decoding, native `framesDecoded`, Android render feedback, closed-surface texture
fallback and real SurfaceHolder replacement. Full input/canvas and recovery
journeys use the same switch.

[Android frame-render timestamps](https://developer.android.com/reference/android/media/MediaCodec.OnFrameRenderedListener)
may be delayed or batched, and callbacks can be missing before Android 14. If
real decoded outputs advance without a presentation callback, the controller
retires that target after six monitoring intervals (about three seconds) and
reconnects using ordinary textures. It tries direct output again only after a
new holder generation. Frame-render timestamps are distinct
from output dequeue, output release, EGL swap and physical scanout. Correctness
on one Qualcomm device does not qualify latency, power, thermal behavior, other
vendor codecs, or a production default. See the repository's implementation
evidence and qualification manifest for completed runs and remaining gates.
