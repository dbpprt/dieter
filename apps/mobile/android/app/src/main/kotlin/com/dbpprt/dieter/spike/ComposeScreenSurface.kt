package com.dbpprt.dieter.spike

import android.content.Context
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.screens.*
import com.dbpprt.dieter.mobile.*
import com.dbpprt.dieter.screens.*

/** The shipping GPU canvas; input/leases/recovery still use the typed core surface. */
internal class ComposeScreenSurface(
    context: Context,
    private val store: MobileStore,
    override val media: AndroidScreenMedia,
) : ScreenCanvasHost, AndroidScreenSurface {
    override val canvas = ScreenCanvas()
    override val view = ScreenCanvasView(context, this)
    private var holding = false
    private var latest = ScreenSlice()
    private var heldPosition = .5 to .5

    override fun send(command: ScreenCommand) =
        store.inputCommand(Command(screen = command.copy(scope = MobileStore.SCREEN_SCOPE)))

    override fun resume() {
        send(ScreenCommand(resume = Step()))
    }

    override fun refresh() {
        send(ScreenCommand(refresh = Step()))
    }

    override fun focus(focused: Boolean) {
        send(ScreenCommand(focused = Toggle(focused)))
    }

    override fun holdCursor(holding: Boolean) {
        if (holding && !this.holding) heldPosition = latest.cursor_x to latest.cursor_y
        this.holding = holding
        if (!holding) update(latest)
    }

    override fun key(hid: Int, down: Boolean, modifiers: Int, repeat: Boolean) {
        send(ScreenCommand(key = ScreenKey(hid, down, repeat, modifiers)))
    }

    override fun text(value: String, modifiers: Int) {
        send(ScreenCommand(text = ScreenText(value, modifiers)))
    }

    override fun releaseInput() {
        send(ScreenCommand(release_input = Step()))
    }

    override fun copy() {
        send(ScreenCommand(clipboard = ScreenClipboardOperation("copy")))
    }

    override fun cut() {
        send(ScreenCommand(clipboard = ScreenClipboardOperation("cut")))
    }

    override fun paste() {
        send(ScreenCommand(clipboard = ScreenClipboardOperation("paste")))
    }

    override fun update(value: ScreenSlice) {
        latest = value
        view.update(
            ScreenView(
                phase = ScreenPhase.of(value.phase, value.problem),
                capabilities = value.capabilities,
                state = value.state,
                controlActive = value.control_active,
                cursorImage = value.cursor_image.takeIf { it.size > 0 },
                cursorX = if (holding) heldPosition.first else value.cursor_x,
                cursorY = if (holding) heldPosition.second else value.cursor_y,
                cursorVisible = value.cursor_visible,
                cursorWidth = value.cursor_width,
                cursorHeight = value.cursor_height,
                cursorHotspotX = value.cursor_hotspot_x,
                cursorHotspotY = value.cursor_hotspot_y,
            )
        )
    }

    override fun control(action: String) {
        when (action) {
            "zoom-in" -> view.zoomCanvas(1.25)
            "zoom-out" -> view.zoomCanvas(0.8)
            "fit" -> view.resetCanvas(animated = true)
            "keyboard-show" -> view.showKeyboard(true)
            "keyboard-hide" -> view.showKeyboard(false)
        }
    }

    override fun close() {
        view.release()
    }
}
