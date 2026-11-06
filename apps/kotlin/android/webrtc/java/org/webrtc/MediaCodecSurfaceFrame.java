/*
 * Copyright 2026 Dieter contributors. All Rights Reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file in the root of the source tree.
 */
package org.webrtc;

import android.os.Handler;
import android.os.Looper;
import java.util.LinkedHashMap;

/** A real dequeued MediaCodec output buffer. Construction is SDK-private.
 * The JNI bridge retains this actual buffer through AndroidVideoBuffer, and
 * receives the normal decode completion for RTP matching and decoder statistics.
 * No compressed-input admission, placeholder pixels or dummy frame counts as output.
 */
final class MediaCodecSurfaceFrame implements VideoFrame.SurfaceBuffer {
  private final Owner owner;
  private final int index;
  private final int width;
  private final int height;
  private final long timestampNs;
  private final long decodedAtNs = System.nanoTime();
  private final RefCountDelegate references = new RefCountDelegate(() -> discard());

  private MediaCodecSurfaceFrame(Owner owner, int index, int width, int height, long timestampNs) {
    this.owner = owner; this.index = index; this.width = width;
    this.height = height; this.timestampNs = timestampNs;
  }
  @Override public int getWidth() { return width; }
  @Override public int getHeight() { return height; }
  @Override public void retain() { references.retain(); }
  @Override public void release() { references.release(); }
  @Override public boolean render() { return owner.release(this, true); }
  @Override public void discard() { owner.release(this, false); }

  // Surface-mode MediaCodec buffers cannot be mapped into an I420 image. A
  // caller requiring pixel conversion must select the ordinary texture path.
  @Override public VideoFrame.I420Buffer toI420() { return null; }
  @Override public VideoFrame.Buffer cropAndScale(int x, int y, int w, int h, int sw, int sh) {
    if (x != 0 || y != 0 || w != width || h != height || sw != width || sh != height)
      throw new UnsupportedOperationException("Transform the owned SurfaceView, not decoder storage");
    retain();
    return this;
  }

  static final class Owner {
    private final MediaCodecWrapper codec;
    private final DecoderSurface surface;
    private final LinkedHashMap<Integer, MediaCodecSurfaceFrame> pending = new LinkedHashMap<>();
    private final LinkedHashMap<Long, Rendered> submitted = new LinkedHashMap<>();
    private boolean closed;
    private boolean reportedInvalidClock;

    private static final class Rendered {
      final MediaCodecSurfaceFrame frame;
      final long releasedAtNs = System.nanoTime();
      Rendered(MediaCodecSurfaceFrame frame) { this.frame = frame; }
    }

    Owner(MediaCodecWrapper codec, DecoderSurface surface) {
      this.codec = codec; this.surface = surface;
      codec.setOnFrameRenderedListener((ignored, ptsUs, nanoTime) -> rendered(ptsUs, nanoTime),
          new Handler(Looper.getMainLooper()));
    }

    synchronized MediaCodecSurfaceFrame acquire(int index, int width, int height, long ptsUs) {
      if (closed) { codec.releaseOutputBuffer(index, false); return null; }
      // Bound decoded output, including frames waiting for reliable generation
      // metadata. Only decoded output is discarded, never compressed references.
      while (pending.size() >= 2) release(pending.values().iterator().next(), false);
      MediaCodecSurfaceFrame frame = new MediaCodecSurfaceFrame(this, index, width, height, ptsUs * 1000);
      if (pending.put(index, frame) != null) throw new IllegalStateException("Codec reused an owned output index");
      return frame;
    }

    synchronized boolean release(MediaCodecSurfaceFrame frame, boolean render) {
      // Object identity fences output-index reuse and late releases after reset.
      if (closed || pending.get(frame.index) != frame) return false;
      pending.remove(frame.index);
      boolean display = render && surface.isOpen();
      if (display) {
        while (submitted.size() >= 32) submitted.remove(submitted.keySet().iterator().next());
        submitted.put(frame.timestampNs / 1000, new Rendered(frame));
      }
      try {
        // Boolean rendering inherits the media PTS as a surface timestamp.
        // RTP-derived PTS is not System.nanoTime: submit NOW explicitly, never
        // a future schedule, and keep media identity only for callback matching.
        if (display) codec.releaseOutputBuffer(frame.index, System.nanoTime());
        else codec.releaseOutputBuffer(frame.index, false);
      }
      catch (RuntimeException failure) {
        submitted.remove(frame.timestampNs / 1000);
        throw failure;
      }
      return display;
    }

    private void rendered(long ptsUs, long nanoTime) {
      final Rendered value;
      synchronized (this) {
        if (closed) return;
        value = submitted.remove(ptsUs);
        long callbackAtNs = System.nanoTime();
        if (value != null && (nanoTime < value.releasedAtNs || nanoTime > callbackAtNs)) {
          // Some emulated/vendor surfaces return a foreign clock. Such a
          // callback cannot measure this output and must not establish readiness
          // or contaminate feedback. The app's bounded watchdog falls back.
          if (!reportedInvalidClock) {
            reportedInvalidClock = true;
            Logging.w("MediaCodecSurfaceFrame", "Ignoring frame-render timestamp outside the local release/callback interval: released="
                + value.releasedAtNs + " rendered=" + nanoTime + " callback=" + callbackAtNs);
          }
          return;
        }
      }
      if (value == null) return;
      MediaCodecSurfaceFrame frame = value.frame;
      surface.rendered(frame.timestampNs, frame.decodedAtNs, value.releasedAtNs,
          nanoTime, frame.width, frame.height);
    }

    synchronized void close() {
      if (closed) return;
      // Called before stopping/releasing the codec, while indices are valid.
      try {
        while (!pending.isEmpty()) release(pending.values().iterator().next(), false);
      } finally { closed = true; pending.clear(); submitted.clear(); }
    }
  }
}
