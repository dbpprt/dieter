package org.webrtc;

import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.media.MediaCodecInfo;
import android.os.Handler;
import android.view.Surface;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Test;
import static org.junit.Assert.*;

/** Real output-index ownership, with a fake codec and an actual Android Surface. */
public class DieterSurfaceOutputTest {
  static class Codec extends DieterLowLatencyCodecTest.Codec {
    final ArrayList<String> outputs = new ArrayList<>();
    final CountDownLatch retired = new CountDownLatch(1);
    MediaCodec.OnFrameRenderedListener listener;
    Codec() { super(false); }
    @Override public void release() { super.release(); retired.countDown(); }
    @Override public void releaseOutputBuffer(int index, boolean render) { outputs.add(index + ":" + render); }
    @Override public void releaseOutputBuffer(int index, long timestampNs) {
      long now = System.nanoTime();
      assertTrue("Direct output must use the local clock, never media PTS or a future queue", timestampNs <= now && now - timestampNs < TimeUnit.SECONDS.toNanos(1));
      outputs.add(index + ":true");
    }
    @Override public void setOnFrameRenderedListener(MediaCodec.OnFrameRenderedListener value, Handler handler) { listener = value; }
    void rendered(long ptsUs) { listener.onFrameRendered(null, ptsUs, System.nanoTime()); }
  }

  static final class Fixture implements AutoCloseable {
    final SurfaceTexture texture = new SurfaceTexture(false);
    final Surface surface = new Surface(texture);
    final Codec codec = new Codec();
    final ArrayList<Long> presented = new ArrayList<>();
    final DecoderSurface target = new DecoderSurface(surface, (pts, decoded, released, rendered, w, h) -> {
      assertTrue(released >= decoded);
      assertTrue(rendered >= released);
      assertEquals(640, w); assertEquals(360, h);
      presented.add(pts);
    });
    final MediaCodecSurfaceFrame.Owner owner = new MediaCodecSurfaceFrame.Owner(codec, target);
    MediaCodecSurfaceFrame frame(int index, long ptsUs) { return owner.acquire(index, 640, 360, ptsUs); }
    @Override public void close() { owner.close(); target.close(); surface.release(); texture.release(); }
  }

  @Test public void outputIsReleasedExactlyOnceDespiteNativeBufferRetention() {
    try (Fixture f = new Fixture()) {
      MediaCodecSurfaceFrame frame = f.frame(3, 9000);
      frame.retain();
      assertTrue(frame.render());
      assertFalse(frame.render());
      frame.release(); frame.release();
      assertEquals(Arrays.asList("3:true"), f.codec.outputs);
      assertEquals(0, f.presented.size());
      f.codec.rendered(9000);
      f.codec.rendered(9000);
      assertEquals(Arrays.asList(9000000L), f.presented);
    }
  }

  @Test public void twoOutputBoundFencesIndexReuseAndLateOwners() {
    try (Fixture f = new Fixture()) {
      MediaCodecSurfaceFrame first = f.frame(0, 1);
      MediaCodecSurfaceFrame second = f.frame(1, 2);
      MediaCodecSurfaceFrame third = f.frame(2, 3);
      assertEquals(Arrays.asList("0:false"), f.codec.outputs);
      assertFalse(first.render());
      MediaCodecSurfaceFrame reused = f.frame(0, 4);
      first.release();
      assertTrue(reused.render());
      second.release(); third.release(); reused.release();
      assertEquals(Arrays.asList("0:false", "1:false", "0:true", "2:false"), f.codec.outputs);
    }
  }

  @Test public void closeDrainsOutputsAndFencesDelayedPresentationCallbacks() {
    try (Fixture f = new Fixture()) {
      MediaCodecSurfaceFrame first = f.frame(0, 1);
      MediaCodecSurfaceFrame second = f.frame(1, 2);
      assertTrue(first.render());
      f.owner.close(); f.owner.close();
      assertFalse(second.render());
      f.codec.rendered(1);
      first.release(); second.release();
      assertEquals(Arrays.asList("0:true", "1:false"), f.codec.outputs);
      assertTrue(f.presented.isEmpty());
    }
  }

  @Test public void decoderCompletionAloneNeverCountsAsPresentation() {
    try (Fixture f = new Fixture()) {
      MediaCodecSurfaceFrame first = f.frame(0, 1);
      MediaCodecSurfaceFrame second = f.frame(1, 2);
      f.codec.rendered(1);
      assertTrue(f.presented.isEmpty());
      first.discard(); assertFalse(first.render());
      assertTrue(second.render());
      f.codec.rendered(123); f.codec.rendered(2);
      assertEquals(Arrays.asList(2000L), f.presented);
      first.release(); second.release();
    }
  }

  @Test public void foreignClockAndPreReleaseTimesNeverCountAsPresentation() {
    try (Fixture f = new Fixture()) {
      MediaCodecSurfaceFrame first = f.frame(0, 1);
      assertTrue(first.render());
      f.codec.listener.onFrameRendered(null, 1, System.nanoTime() + TimeUnit.HOURS.toNanos(1));
      MediaCodecSurfaceFrame second = f.frame(1, 2);
      assertTrue(second.render());
      f.codec.listener.onFrameRendered(null, 2, 1);
      assertTrue(f.presented.isEmpty());
      MediaCodecSurfaceFrame valid = f.frame(2, 3);
      assertTrue(valid.render()); f.codec.rendered(3);
      assertEquals(Arrays.asList(3000L), f.presented);
      first.release(); second.release(); valid.release();
    }
  }

  @Test public void holderInvalidationStopsItsCodecAndCannotBeReused() {
    try (Fixture f = new Fixture()) {
      int[] stops = {0};
      Runnable stop = () -> { stops[0]++; f.owner.close(); };
      assertEquals(VideoCodecStatus.OK, f.target.configure(stop, s -> VideoCodecStatus.OK));
      assertEquals(VideoCodecStatus.FALLBACK_SOFTWARE, f.target.configure(() -> {}, s -> VideoCodecStatus.OK));
      MediaCodecSurfaceFrame frame = f.frame(0, 1);
      f.target.close(); f.target.close();
      assertEquals(1, stops[0]);
      assertTrue(f.surface.isValid()); // the holder, not the SDK, owns the Surface
      assertFalse(frame.render()); frame.release();
      assertEquals(VideoCodecStatus.FALLBACK_SOFTWARE, f.target.configure(stop, s -> VideoCodecStatus.OK));
      assertEquals(Arrays.asList("0:false"), f.codec.outputs);
    }
  }

  @Test public void opaqueSurfaceFormatDecodesAndFormatFailureCanReinitialize() throws Exception {
    try (Fixture f = new Fixture()) {
      ArrayList<Codec> codecs = new ArrayList<>();
      MediaCodecWrapperFactory factory = name -> {
        Codec codec = new Codec() {
          int outputs;
          @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo info, long timeout) {
            int n = outputs++;
            if (n == 0 || n == 2) return MediaCodec.INFO_OUTPUT_FORMAT_CHANGED;
            if (n == 1) { info.presentationTimeUs = 1000; return 0; }
            try { Thread.sleep(2); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return MediaCodec.INFO_TRY_AGAIN_LATER;
          }
          @Override public MediaFormat getOutputFormat() {
            MediaFormat format = MediaFormat.createVideoFormat("video/avc", outputs > 2 ? 641 : 640, 360);
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            return format;
          }
        };
        codecs.add(codec); return codec;
      };
      AndroidVideoDecoder decoder = new AndroidVideoDecoder(factory, "test", VideoCodecMimeType.H264,
          MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar, null, f.target);
      java.util.concurrent.atomic.AtomicInteger outputs = new java.util.concurrent.atomic.AtomicInteger();
      decoder.setDecodedOutputCallback(timestamp -> {
        assertEquals(1000000L, timestamp);
        outputs.incrementAndGet();
      });
      for (int attempt = 0; attempt < 2; attempt++) {
        CountDownLatch decoded = new CountDownLatch(1);
        assertEquals(VideoCodecStatus.OK, decoder.initDecode(new VideoDecoder.Settings(1, 640, 360), (frame, ms, qp) -> {
          assertTrue(frame.getBuffer() instanceof VideoFrame.SurfaceBuffer);
          assertEquals(1000000L, frame.getTimestampNs());
          decoded.countDown();
        }));
        assertTrue("Opaque surface output must reach decode completion", decoded.await(2, TimeUnit.SECONDS));
        assertEquals("Observe each real output, never a format/try-again code", attempt + 1, outputs.get());
        // Wait for the invalid size change to stop the worker before release.
        // A false running flag must not skip joining/resetting this failed codec.
        assertTrue(codecs.get(attempt).retired.await(2, TimeUnit.SECONDS));
        assertEquals(VideoCodecStatus.ERROR, decoder.release());
        assertEquals(1, codecs.get(attempt).releases);
      }
    }
  }

  @Test public void rejectedDirectConfigurationFallsBackOnceToARealTextureSurface() {
    try (Fixture f = new Fixture()) {
      EglBase egl = EglBase.create();
      ArrayList<Codec> codecs = new ArrayList<>();
      ArrayList<Surface> configured = new ArrayList<>();
      MediaCodecWrapperFactory factory = name -> {
        Codec codec = new Codec() {
          @Override public void configure(MediaFormat format, Surface surface, android.media.MediaCrypto crypto, int flags) {
            configured.add(surface);
            if (surface == f.surface) throw new IllegalArgumentException("injected direct surface rejection");
          }
          @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo info, long timeout) {
            try { Thread.sleep(2); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            return MediaCodec.INFO_TRY_AGAIN_LATER;
          }
        };
        codecs.add(codec); return codec;
      };
      AndroidVideoDecoder decoder = new AndroidVideoDecoder(factory, "test", VideoCodecMimeType.H264,
          MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar, egl.getEglBaseContext(), f.target);
      try {
        assertEquals(VideoCodecStatus.OK, decoder.initDecode(new VideoDecoder.Settings(1, 640, 360), (frame, ms, qp) -> {}));
        assertEquals(2, codecs.size());
        assertSame(f.surface, configured.get(0));
        assertNotSame(f.surface, configured.get(1));
        assertTrue(configured.get(1).isValid());
        assertEquals(1, codecs.get(0).releases);
      } finally { decoder.release(); egl.release(); }
      assertEquals(1, codecs.get(1).releases);
      assertTrue(f.surface.isValid());
    }
  }

  @Test public void busyTextureOutputStillReportsActualDecoderCompletion() throws Exception {
    EglBase egl = EglBase.create();
    Codec codec = new Codec() {
      int outputs;
      @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo info, long timeout) {
        if (outputs < 3) {
          info.presentationTimeUs = (outputs + 1) * 1000L;
          return outputs++;
        }
        try { Thread.sleep(2); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        return MediaCodec.INFO_TRY_AGAIN_LATER;
      }
    };
    AndroidVideoDecoder decoder = new AndroidVideoDecoder(name -> codec, "test", VideoCodecMimeType.H264,
        MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar, egl.getEglBaseContext());
    ArrayList<Long> completions = new ArrayList<>();
    CountDownLatch decoded = new CountDownLatch(3);
    java.util.concurrent.atomic.AtomicInteger textures = new java.util.concurrent.atomic.AtomicInteger();
    decoder.setDecodedOutputCallback(timestamp -> { completions.add(timestamp); decoded.countDown(); });
    try {
      assertEquals(VideoCodecStatus.OK, decoder.initDecode(new VideoDecoder.Settings(1, 640, 360),
          (frame, ms, qp) -> textures.incrementAndGet()));
      assertTrue(decoded.await(2, TimeUnit.SECONDS));
    } finally {
      assertEquals(VideoCodecStatus.OK, decoder.release());
      egl.release();
    }
    // The fake codec never posts pixels to the real texture surface. Its first
    // output remains pending there; subsequent decoded outputs are discarded.
    assertEquals(Arrays.asList(1000000L, 2000000L, 3000000L), completions);
    assertEquals(Arrays.asList("0:true", "1:false", "2:false"), codec.outputs);
    assertEquals(0, textures.get());
  }

  @Test public void timedOutDirectWorkerRetainsItsTargetUntilCodecRetires() throws Exception {
    try (Fixture f = new Fixture()) {
      CountDownLatch entered = new CountDownLatch(1), unblock = new CountDownLatch(1);
      Codec codec = new Codec() {
        @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo info, long timeout) {
          entered.countDown();
          try { unblock.await(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
          info.presentationTimeUs = 1000;
          return 0;
        }
      };
      AtomicInteger allocations = new AtomicInteger(), callbacks = new AtomicInteger();
      AndroidVideoDecoder decoder = new AndroidVideoDecoder(name -> { allocations.incrementAndGet(); return codec; },
          "test", VideoCodecMimeType.H264, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar, null, f.target);
      VideoDecoder.Settings settings = new VideoDecoder.Settings(1, 640, 360);
      assertEquals(VideoCodecStatus.OK, decoder.initDecode(settings, (frame, ms, qp) -> callbacks.incrementAndGet()));
      try {
        assertTrue(entered.await(2, TimeUnit.SECONDS));
        assertEquals(VideoCodecStatus.TIMEOUT, decoder.release());
        assertEquals(VideoCodecStatus.FALLBACK_SOFTWARE, decoder.initDecode(settings, (frame, ms, qp) -> fail("Retired callback")));
        assertEquals(1, allocations.get());
        assertEquals(VideoCodecStatus.FALLBACK_SOFTWARE, f.target.configure(() -> {}, s -> VideoCodecStatus.OK));
      } finally {
        unblock.countDown();
        assertEquals(VideoCodecStatus.OK, decoder.release());
      }
      assertEquals(0, callbacks.get());
      assertEquals(Arrays.asList("0:false"), codec.outputs);
      assertEquals(1, codec.releases);
      assertTrue(f.surface.isValid());
    }
  }
}
