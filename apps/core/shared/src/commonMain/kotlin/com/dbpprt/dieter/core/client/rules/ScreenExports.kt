package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ScreenCodecOption
import com.dbpprt.dieter.client.v1.ScreenQualityOption
import com.dbpprt.dieter.client.v1.ScreenStreamOptions
import com.dbpprt.dieter.client.v1.ScreenToolbarKey
import com.dbpprt.dieter.client.v1.ScreenToolbarKeys
import com.dbpprt.dieter.core.screens.ScreenCodecs
import com.dbpprt.dieter.core.screens.ScreenKeyboard
import com.dbpprt.dieter.core.screens.ScreenOptions
import com.dbpprt.dieter.core.screens.ScreenPhase

/** Shared screen presentation that screen views and touch toolbars read while rendering. */
object ScreenExports {
    private val toolbarKeys = ScreenToolbarKeys(
        modifiers = ScreenKeyboard.MODIFIER_KEYS.map(::key),
        special = ScreenKeyboard.SPECIAL_KEYS.map(::key),
    )

    private val streamOptions = ScreenStreamOptions(
        qualities = ScreenOptions.qualities.map { ScreenQualityOption(it.label, it.value) },
        codecs = ScreenOptions.codecs.map { ScreenCodecOption(it.label, it.value) },
    )

    /** The modifier toggles and special keys a touch screen's toolbar offers, as Android shows them. */
    fun toolbarKeys(): ScreenToolbarKeys = toolbarKeys

    /** The quality and codec choices a screen's options offer, in menu order. */
    fun streamOptions(): ScreenStreamOptions = streamOptions

    /** A frame-rate choice: "Up to 60 fps". */
    fun frameRate(fps: Int): String = ScreenOptions.frameRate(fps)

    /** The button that takes or releases control: "Take Control", or "Release Control" while [controlActive]. */
    fun controlAction(controlActive: Boolean): String = ScreenOptions.controlAction(controlActive)

    /** Why a session cannot start when the device decodes none of the codecs it may receive. */
    fun codecUnavailable(): String = ScreenCodecs.UNAVAILABLE

    /**
     * What a screen view says while not streaming, from the screen slice's
     * `phase` and `problem` and the machine's `remote_desktop_ready` and
     * `remote_desktop_reason`: why no session can run, else why the host
     * cannot share, else the phase.
     */
    fun waitingMessage(phase: String, problem: String, hostReady: Boolean, hostReason: String): String =
        ScreenPhase.of(phase, problem).waitingMessage(hostReady, hostReason)

    private fun key(value: ScreenKeyboard.ToolbarKey) = ScreenToolbarKey(label = value.label, hid = value.hid, modifier = value.modifier)
}
