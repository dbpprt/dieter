package com.dbpprt.dieter.screens

import org.webrtc.*
import android.media.MediaCodecInfo
import android.os.Build
import java.util.concurrent.atomic.AtomicBoolean

/** Native MediaCodec -> shared EGL texture. No bitmap copies or encoded-frame queues.
 * Render at decode completion; desktop frames have no audio clock to synchronize to.
 * The normal WebRTC callback is retained for decoder/reference management and statistics.
 */
internal class ScreenDecoderFactory(
    context: EglBase.Context, private val enableHEVC: Boolean = false,
    lowLatency: Boolean = false, private val configured: (ScreenDecoderStatus) -> Unit = {},
    directSurface: () -> DecoderSurface? = { null },
    private val outputDecoded: (Long) -> Unit = {},
    private val unavailable: () -> Unit = {}, private val decoded: (VideoFrame) -> Unit,
) : VideoDecoderFactory {
    private val listener = DieterLowLatencyDecoderFactory.Listener { name, requested, accepted, reason ->
        configured(ScreenDecoderStatus(name, true, requested, accepted, reason))
    }
    private val hardware = DieterLowLatencyDecoderFactory(context, { true }, lowLatency, listener, directSurface, outputDecoded)
    private val platform = PlatformSoftwareVideoDecoderFactory(context)
    private val hevcHardware = DieterLowLatencyDecoderFactory(context, { supportsHEVC(it) }, lowLatency, listener, directSurface, outputDecoded)
    override fun getSupportedCodecs(): Array<VideoCodecInfo> =
        ((if (enableHEVC) hevcHardware.supportedCodecs.filter { it.name.equals("H265", true) }.map {
            VideoCodecInfo("H265", mapOf("profile-id" to "1", "tier-flag" to "0", "level-id" to "153", "tx-mode" to "SRST"), emptyList())
        } else emptyList()) + (hardware.supportedCodecs.toList() + platform.supportedCodecs.toList())
            .filter { it.name.equals("H264", true) }).distinctBy { it.name to it.params }.toTypedArray()

    override fun createDecoder(info: VideoCodecInfo): VideoDecoder? {
        val hevc = info.name.equals("H265", true)
        if (!info.name.equals("H264", true) && !(enableHEVC && hevc)) return null
        val decoder = if (hevc) hevcHardware.createDecoder(info) else hardware.createDecoder(info) ?: platform.createDecoder(info)?.also {
            configured(ScreenDecoderStatus(it.implementationName, false, false, false, "platform software fallback"))
        }
        if (decoder == null) { if (hevc) unavailable(); return null }
        val hasDecoded = AtomicBoolean()
        val reported = AtomicBoolean()
        fun check(status: VideoCodecStatus): VideoCodecStatus {
            if (hevc && !hasDecoded.get() && status.number < 0 && reported.compareAndSet(false, true)) unavailable()
            return status
        }
        return object : VideoDecoder {
            override fun initDecode(settings: VideoDecoder.Settings, callback: VideoDecoder.Callback): VideoCodecStatus =
                check(decoder.initDecode(settings) { frame, time, qp ->
                    hasDecoded.set(true)
                    // Software/platform fallback may not expose the dequeue
                    // hook. The receiver deduplicates the hardware's two paths.
                    outputDecoded(frame.timestampNs)
                    decoded(frame)
                    callback.onDecodedFrame(frame, time, qp)
                })
            override fun decode(frame: EncodedImage, info: VideoDecoder.DecodeInfo?) = check(decoder.decode(frame, info))
            override fun release() = decoder.release()
            override fun getImplementationName() = decoder.implementationName
        }
    }
    companion object {
        internal fun supportsHEVC(info: MediaCodecInfo): Boolean = runCatching {
            Build.VERSION.SDK_INT >= 29 && !info.isEncoder && info.isHardwareAccelerated && !info.isSoftwareOnly &&
                info.getCapabilitiesForType("video/hevc").let { caps ->
                    caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain &&
                        it.level >= MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51 } &&
                        caps.videoCapabilities?.areSizeAndRateSupported(1920, 1080, 60.0) == true
                }
        }.getOrDefault(false)
    }
}

data class ScreenDecoderStatus(val implementation: String, val hardware: Boolean,
    val lowLatencyRequested: Boolean, val lowLatencyAccepted: Boolean, val reason: String)

/** The Android decoder API carries RTP time as floor(timestamp / 90) milliseconds.
 * Compare on the wrapping 32-bit RTP clock, allowing only its sub-ms quantization.
 */
internal fun belongsToGeneration(timestampNs: Long, boundary: Int): Boolean {
    val rtp = (timestampNs / 1_000_000L * 90L) and 0xffff_ffffL
    val floorBoundary = (boundary.toLong() and 0xffff_ffffL) / 90L * 90L
    return ((rtp - floorBoundary) and 0xffff_ffffL) < 0x8000_0000L
}
