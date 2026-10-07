package com.dbpprt.dieter.screens

import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.core.screens.ScreenCanvas

/** Native canvas callbacks; both mobile hosts keep session policy in the core. */
interface ScreenCanvasHost {
    val media: AndroidScreenMedia
    val canvas: ScreenCanvas

    fun resume()

    fun refresh()

    fun focus(focused: Boolean)

    fun holdCursor(holding: Boolean)

    fun key(hid: Int, down: Boolean, modifiers: Int = 0, repeat: Boolean = false)

    fun text(value: String, modifiers: Int = 0)

    fun releaseInput()

    fun send(command: ScreenCommand)

    fun copy()

    fun cut()

    fun paste()
}
