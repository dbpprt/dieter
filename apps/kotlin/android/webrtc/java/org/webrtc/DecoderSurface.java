/*
 * Copyright 2026 Dieter contributors. All Rights Reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file in the root of the source tree.
 */
package org.webrtc;

import android.view.Surface;

/** A borrowed decoder output Surface, valid for one SurfaceHolder generation.
 *
 * The owner must close this object before returning from surfaceDestroyed. Close
 * fences new submissions and synchronously stops the attached decoder; it never
 * releases the borrowed Surface. Use a new object for every new holder generation.
 * Only a surface-aware sink may consume frames decoded through this API.
 */
public final class DecoderSurface implements AutoCloseable {
  public interface Listener {
    /** MediaCodec's frame-render callback, not a scanout/physical photon time.
     * Callbacks may be delayed or batched. All times use System.nanoTime's domain.
     */
    void onFrameRendered(long timestampNs, long decodedAtNs, long releasedAtNs,
        long renderedAtNs, int width, int height);
  }

  interface Configuration { VideoCodecStatus configure(Surface surface); }
  private final Surface surface;
  private final Listener listener;
  private boolean closed;
  private Runnable stop;

  public DecoderSurface(Surface surface, Listener listener) {
    if (surface == null || listener == null) throw new IllegalArgumentException("Surface and listener required");
    this.surface = surface;
    this.listener = listener;
  }

  // Configuration/start is atomic with holder invalidation. A second decoder
  // cannot silently steal a Surface that still belongs to a live codec.
  synchronized VideoCodecStatus configure(Runnable owner, Configuration action) {
    if (closed || !surface.isValid() || (stop != null && stop != owner)) return VideoCodecStatus.FALLBACK_SOFTWARE;
    stop = owner;
    return action.configure(surface);
  }

  public synchronized boolean isOpen() { return !closed && surface.isValid(); }
  synchronized void detach(Runnable owner) { if (stop == owner) stop = null; }

  void rendered(long timestampNs, long decodedAtNs, long releasedAtNs,
      long renderedAtNs, int width, int height) {
    synchronized (this) { if (closed) return; }
    // Never call client code with the holder lock held. Clients must also fence
    // their session/surface generation when dispatching delayed callbacks.
    listener.onFrameRendered(timestampNs, decodedAtNs, releasedAtNs, renderedAtNs, width, height);
  }

  @Override public void close() {
    final Runnable owner;
    synchronized (this) {
      if (closed) return;
      closed = true;
      owner = stop;
      stop = null;
    }
    // Do not hold the surface lock while joining the decoder output thread.
    if (owner != null) owner.run();
  }
}
