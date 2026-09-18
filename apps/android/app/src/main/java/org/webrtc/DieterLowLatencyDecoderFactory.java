package org.webrtc;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaCrypto;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.view.Surface;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.function.Supplier;
import java.util.function.LongConsumer;

/** Adapter to the pinned M150 SDK's package-private codec-wrapper injection seam.
 * No reflection, duplicate runtime classes, JNI changes, or placeholder frames.
 * The source-pinned SDK extends real decoder storage for optional direct output;
 * the ordinary texture callback/reference path is preserved.
 */
public final class DieterLowLatencyDecoderFactory extends HardwareVideoDecoderFactory {
  public interface Listener {
    void configured(String codec, boolean requested, boolean accepted, String reason);
  }
  private final EglBase.Context context;
  private final boolean enabled;
  private final Listener listener;
  private final Supplier<DecoderSurface> surface;
  private final LongConsumer decodedOutput;

  public DieterLowLatencyDecoderFactory(EglBase.Context context, Predicate<MediaCodecInfo> allowed,
      boolean enabled, Listener listener) {
    this(context, allowed, enabled, listener, () -> null);
  }

  public DieterLowLatencyDecoderFactory(EglBase.Context context, Predicate<MediaCodecInfo> allowed,
      boolean enabled, Listener listener, Supplier<DecoderSurface> surface) {
    this(context, allowed, enabled, listener, surface, timestampNs -> {});
  }

  public DieterLowLatencyDecoderFactory(EglBase.Context context, Predicate<MediaCodecInfo> allowed,
      boolean enabled, Listener listener, Supplier<DecoderSurface> surface, LongConsumer decodedOutput) {
    super(context, allowed);
    this.context = context;
    this.enabled = enabled;
    this.listener = listener;
    this.surface = surface;
    this.decodedOutput = decodedOutput;
  }

  @Override public VideoDecoder createDecoder(VideoCodecInfo info) {
    VideoDecoder original = super.createDecoder(info);
    if (original == null) return null;
    observeOutput(original);
    String name = original.getImplementationName();
    DecoderSurface output = surface.get();
    if (output == null && (!enabled || Build.VERSION.SDK_INT < 30)) {
      listener.configured(name, false, false, enabled ? "Android API below 30" : "disabled");
      return original;
    }
    VideoCodecMimeType type = VideoCodecMimeType.valueOf(info.name);
    for (MediaCodecInfo codec : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
      if (!codec.getName().equals(name)) continue;
      try {
        MediaCodecInfo.CodecCapabilities caps = codec.getCapabilitiesForType(type.mimeType());
        Integer color = MediaCodecUtils.selectColorFormat(MediaCodecUtils.DECODER_COLOR_FORMATS, caps);
        boolean lowLatency = enabled && Build.VERSION.SDK_INT >= 30 &&
            caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency);
        if (color != null && (lowLatency || output != null)) {
          // Constructing the original decoder above does not create a MediaCodec;
          // initDecode owns allocation. Reuse its exact codec/profile selection.
          MediaCodecWrapperFactory factory = lowLatency ? codecName -> new LowLatencyCodec(codecName,
              new MediaCodecWrapperFactoryImpl(), listener) : new MediaCodecWrapperFactoryImpl();
          if (!lowLatency) listener.configured(name, false, false,
              enabled ? "low-latency feature not advertised" : "disabled");
          return observeOutput(new AndroidVideoDecoder(factory, name, type, color, context, output));
        }
      } catch (IllegalArgumentException unsupported) {
        listener.configured(name, false, false, "codec capability query rejected");
        return original;
      }
      break;
    }
    listener.configured(name, false, false, "low-latency feature not advertised");
    return original;
  }

  private VideoDecoder observeOutput(VideoDecoder decoder) {
    if (decoder instanceof AndroidVideoDecoder) {
      ((AndroidVideoDecoder) decoder).setDecodedOutputCallback(decodedOutput);
    }
    return decoder;
  }

  static final class LowLatencyCodec implements MediaCodecWrapper {
    private final String name;
    private final MediaCodecWrapperFactory factory;
    private final Listener listener;
    private MediaCodecWrapper codec;
    private MediaFormat format;
    private Surface surface;
    private MediaCrypto crypto;
    private int flags;
    private boolean optionalConfigured;
    private boolean released;

    LowLatencyCodec(String name, MediaCodecWrapperFactory factory, Listener listener) throws IOException {
      this.name = name; this.factory = factory; this.listener = listener;
      codec = factory.createByCodecName(name);
    }
    @Override public void configure(MediaFormat format, Surface surface, MediaCrypto crypto, int flags) {
      this.format = format; this.surface = surface; this.crypto = crypto; this.flags = flags;
      format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
      try {
        codec.configure(format, surface, crypto, flags);
      } catch (RuntimeException rejected) {
        // Recreate after failed configuration; retrying a half-configured codec
        // in place is not portable. Exactly one ordinary-mode fallback.
        ordinaryFallback(rejected, "configuration");
        return;
      }
      optionalConfigured = true;
      listener.configured(name, true, true, "configuration accepted; timing requires measurement");
    }
    private void ordinaryFallback(RuntimeException rejected, String stage) {
      optionalConfigured = false;
      releaseCodec();
      try { codec = factory.createByCodecName(name); }
      catch (IOException failure) { throw new IllegalStateException("Decoder fallback creation failed", failure); }
      released = false;
      // Production creates this wrapper only when Android advertises the
      // API-30 low-latency feature. Keep the API guard explicit so the app's
      // API-26 class path never invokes MediaFormat.removeKey (API 29).
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        format.removeKey(MediaFormat.KEY_LOW_LATENCY);
      } else {
        throw new IllegalStateException("Low-latency decoder requires Android 11");
      }
      codec.configure(format, surface, crypto, flags);
      listener.configured(name, true, false, "low-latency " + stage + " rejected: " + rejected.getClass().getSimpleName());
    }
    @Override public void start() {
      try { codec.start(); }
      catch (RuntimeException rejected) {
        if (!optionalConfigured) throw rejected;
        // Some codecs accept configure but reject the mode during allocation.
        // No input has been queued yet. Share the same one-recreation budget.
        ordinaryFallback(rejected, "start");
        codec.start();
      }
    }
    @Override public void flush() { codec.flush(); }
    private void releaseCodec() { if (!released) { released = true; codec.release(); } }
    @Override public void stop() { if (!released) codec.stop(); }
    @Override public void release() { releaseCodec(); }
    @Override public int dequeueInputBuffer(long timeoutUs) { return codec.dequeueInputBuffer(timeoutUs); }
    @Override public void queueInputBuffer(int index, int offset, int size, long pts, int flags) { codec.queueInputBuffer(index, offset, size, pts, flags); }
    @Override public int dequeueOutputBuffer(MediaCodec.BufferInfo info, long timeoutUs) { return codec.dequeueOutputBuffer(info, timeoutUs); }
    @Override public void releaseOutputBuffer(int index, boolean render) { codec.releaseOutputBuffer(index, render); }
    @Override public void releaseOutputBuffer(int index, long renderTimestampNs) { codec.releaseOutputBuffer(index, renderTimestampNs); }
    @Override public void setOnFrameRenderedListener(MediaCodec.OnFrameRenderedListener listener, Handler handler) {
      codec.setOnFrameRenderedListener(listener, handler);
    }
    @Override public MediaFormat getInputFormat() { return codec.getInputFormat(); }
    @Override public MediaFormat getOutputFormat() { return codec.getOutputFormat(); }
    @Override public MediaFormat getOutputFormat(int index) { return codec.getOutputFormat(index); }
    @Override public ByteBuffer getInputBuffer(int index) { return codec.getInputBuffer(index); }
    @Override public ByteBuffer getOutputBuffer(int index) { return codec.getOutputBuffer(index); }
    @Override public Surface createInputSurface() { return codec.createInputSurface(); }
    @Override public void setParameters(Bundle parameters) { codec.setParameters(parameters); }
    @Override public MediaCodecInfo getCodecInfo() { return codec.getCodecInfo(); }
  }
}
