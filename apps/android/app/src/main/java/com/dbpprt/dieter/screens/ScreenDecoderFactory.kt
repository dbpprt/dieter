package com.dbpprt.dieter.screens

import org.webrtc.*

/** Native MediaCodec -> shared EGL texture. No bitmap copies or encoded-frame queues.
 * Render at decode completion; desktop frames have no audio clock to synchronize to.
 * The normal WebRTC callback is retained for decoder/reference management and statistics.
 */
internal class ScreenDecoderFactory(context: EglBase.Context, private val decoded: (VideoFrame) -> Unit) : VideoDecoderFactory {
    private val hardware = HardwareVideoDecoderFactory(context)
    private val platform = PlatformSoftwareVideoDecoderFactory(context)
    override fun getSupportedCodecs(): Array<VideoCodecInfo> =
        (hardware.supportedCodecs.toList() + platform.supportedCodecs.toList())
            .filter { it.name.equals("H264", true) }.distinctBy { it.name to it.params }.toTypedArray()

    override fun createDecoder(info: VideoCodecInfo): VideoDecoder? {
        if (!info.name.equals("H264", true)) return null
        val decoder = hardware.createDecoder(info) ?: platform.createDecoder(info) ?: return null
        return object : VideoDecoder {
            override fun initDecode(settings: VideoDecoder.Settings, callback: VideoDecoder.Callback): VideoCodecStatus =
                decoder.initDecode(settings) { frame, time, qp ->
                    decoded(frame)
                    callback.onDecodedFrame(frame, time, qp)
                }
            override fun decode(frame: EncodedImage, info: VideoDecoder.DecodeInfo?) = decoder.decode(frame, info)
            override fun release() = decoder.release()
            override fun getImplementationName() = decoder.implementationName
        }
    }
}

/** The Android decoder API carries RTP time as floor(timestamp / 90) milliseconds.
 * Compare on the wrapping 32-bit RTP clock, allowing only its sub-ms quantization.
 */
internal fun belongsToGeneration(timestampNs: Long, boundary: Int): Boolean {
    val rtp = (timestampNs / 1_000_000L * 90L) and 0xffff_ffffL
    val floorBoundary = (boundary.toLong() and 0xffff_ffffL) / 90L * 90L
    return ((rtp - floorBoundary) and 0xffff_ffffL) < 0x8000_0000L
}
