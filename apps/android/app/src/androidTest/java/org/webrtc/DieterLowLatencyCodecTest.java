package org.webrtc;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCrypto;
import android.media.MediaFormat;
import android.os.Bundle;
import android.view.Surface;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import org.junit.Test;
import static org.junit.Assert.*;

public class DieterLowLatencyCodecTest {
  static class Codec implements MediaCodecWrapper {
    final boolean reject;
    int releases;
    boolean rejectStart;
    boolean lowLatency;
    Codec(boolean reject) { this.reject = reject; }
    @Override public void configure(MediaFormat f, Surface s, MediaCrypto c, int flags) {
      lowLatency = f.containsKey(MediaFormat.KEY_LOW_LATENCY);
      if (reject) throw new IllegalArgumentException("injected codec rejection");
    }
    @Override public void start() { if (rejectStart) throw new IllegalStateException("injected start rejection"); }
    @Override public void flush() {}
    @Override public void stop() {}
    @Override public void release() { releases++; }
    @Override public int dequeueInputBuffer(long timeout) { return 0; }
    @Override public void queueInputBuffer(int i, int o, int s, long t, int f) {}
    @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo i, long t) { return 0; }
    @Override public void releaseOutputBuffer(int i, boolean r) {}
    @Override public void releaseOutputBuffer(int i, long timestampNs) { releaseOutputBuffer(i, true); }
    @Override public MediaFormat getInputFormat() { return new MediaFormat(); }
    @Override public MediaFormat getOutputFormat() { return new MediaFormat(); }
    @Override public MediaFormat getOutputFormat(int i) { return new MediaFormat(); }
    @Override public ByteBuffer getInputBuffer(int i) { return null; }
    @Override public ByteBuffer getOutputBuffer(int i) { return null; }
    @Override public Surface createInputSurface() { return null; }
    @Override public void setParameters(Bundle p) {}
    @Override public MediaCodecInfo getCodecInfo() { return null; }
  }

  @Test public void acceptedSettingPreservesTheOriginalFormat() throws Exception {
    Codec codec = new Codec(false);
    boolean[] accepted = {false};
    DieterLowLatencyDecoderFactory.LowLatencyCodec wrapper = new DieterLowLatencyDecoderFactory.LowLatencyCodec(
        "test", name -> codec, (name, requested, success, reason) -> accepted[0] = requested && success);
    MediaFormat format = MediaFormat.createVideoFormat("video/avc", 1920, 1080);
    wrapper.configure(format, null, null, 0);
    assertTrue(codec.lowLatency);
    assertTrue(accepted[0]);
    assertEquals(1920, format.getInteger(MediaFormat.KEY_WIDTH));
    wrapper.release();
    assertEquals(1, codec.releases);
  }

  @Test public void rejectedSettingRecreatesExactlyOnceWithoutTheKey() throws Exception {
    ArrayList<Codec> codecs = new ArrayList<>();
    boolean[] reported = {false};
    DieterLowLatencyDecoderFactory.LowLatencyCodec wrapper = new DieterLowLatencyDecoderFactory.LowLatencyCodec(
        "test", name -> { Codec codec = new Codec(codecs.isEmpty()); codecs.add(codec); return codec; },
        (name, requested, accepted, reason) -> reported[0] = requested && !accepted && reason.contains("rejected"));
    wrapper.configure(MediaFormat.createVideoFormat("video/avc", 1920, 1080), null, null, 0);
    assertEquals(2, codecs.size());
    assertEquals(1, codecs.get(0).releases);
    assertTrue(codecs.get(0).lowLatency);
    assertFalse(codecs.get(1).lowLatency);
    assertTrue(reported[0]);
    wrapper.release();
    assertEquals(1, codecs.get(1).releases);
  }

  @Test public void ordinaryConfigurationFailureDoesNotLoop() throws Exception {
    ArrayList<Codec> codecs = new ArrayList<>();
    DieterLowLatencyDecoderFactory.LowLatencyCodec wrapper = new DieterLowLatencyDecoderFactory.LowLatencyCodec(
        "test", name -> { Codec codec = new Codec(true); codecs.add(codec); return codec; }, (n, r, a, why) -> {});
    try {
      assertThrows(IllegalArgumentException.class, () -> wrapper.configure(
          MediaFormat.createVideoFormat("video/avc", 1920, 1080), null, null, 0));
      assertEquals(2, codecs.size());
    } finally { wrapper.release(); }
    assertEquals(1, codecs.get(0).releases);
    assertEquals(1, codecs.get(1).releases);
  }

  @Test public void rejectedStartSharesTheSingleRecreationBudget() throws Exception {
    for (boolean rejectOrdinaryStart : new boolean[]{false, true}) {
      ArrayList<Codec> codecs = new ArrayList<>();
      ArrayList<Boolean> accepted = new ArrayList<>();
      DieterLowLatencyDecoderFactory.LowLatencyCodec wrapper = new DieterLowLatencyDecoderFactory.LowLatencyCodec(
          "test", name -> {
            Codec codec = new Codec(false);
            codec.rejectStart = codecs.isEmpty() || rejectOrdinaryStart;
            codecs.add(codec); return codec;
          }, (name, requested, success, reason) -> accepted.add(success));
      wrapper.configure(MediaFormat.createVideoFormat("video/avc", 1920, 1080), null, null, 0);
      try {
        if (rejectOrdinaryStart) assertThrows(IllegalStateException.class, wrapper::start);
        else wrapper.start();
        assertEquals(2, codecs.size());
        assertFalse(codecs.get(1).lowLatency);
        assertEquals(java.util.Arrays.asList(true, false), accepted);
      } finally { wrapper.release(); }
      assertEquals(1, codecs.get(0).releases);
      assertEquals(1, codecs.get(1).releases);
    }
  }

  @Test public void failedReplacementCreationDoesNotReleaseTheRetiredCodecTwice() throws Exception {
    Codec codec = new Codec(true);
    int[] creations = {0};
    DieterLowLatencyDecoderFactory.LowLatencyCodec wrapper = new DieterLowLatencyDecoderFactory.LowLatencyCodec(
        "test", name -> {
          if (creations[0]++ > 0) throw new java.io.IOException("injected creation failure");
          return codec;
        }, (n, r, a, why) -> {});
    assertThrows(IllegalStateException.class, () -> wrapper.configure(
        MediaFormat.createVideoFormat("video/avc", 1920, 1080), null, null, 0));
    wrapper.stop(); wrapper.release(); wrapper.release();
    assertEquals(2, creations[0]);
    assertEquals(1, codec.releases);
  }
}
