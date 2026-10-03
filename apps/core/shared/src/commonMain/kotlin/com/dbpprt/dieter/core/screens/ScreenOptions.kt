package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality

/** The stream choices a screen's options offer and the control button, worded once for every client. */
object ScreenOptions {
    /** One choice: what the menu shows and the preference it sets. */
    data class Choice<T>(val label: String, val value: T)

    /** The quality choices, in menu order. */
    val qualities: List<Choice<RemoteDesktopQuality>> = listOf(
        Choice("Automatic quality", RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_AUTO),
        Choice("Sharp text", RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL),
        Choice("Responsive motion", RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION),
    )

    /** The codec choices, in menu order. */
    val codecs: List<Choice<RemoteDesktopCodecPreference>> = listOf(
        Choice("Automatic codec", RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO),
        Choice("H.264 compatibility", RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264),
        Choice("HEVC · up to 1080p60", RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC),
    )

    /** A frame-rate choice: "Up to 60 fps". */
    fun frameRate(fps: Int): String = "Up to $fps fps"

    /** The button that takes or releases control. */
    fun controlAction(controlActive: Boolean): String = if (controlActive) "Release Control" else "Take Control"
}
