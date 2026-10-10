package com.dbpprt.dieter.screens

import android.text.Editable
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import com.dbpprt.dieter.core.screens.ScreenKeyboard
import com.dbpprt.dieter.core.screens.Typed

/** Android IME adaptation; all paths use the existing text and HID input operations. */
internal class ScreenInputConnection(
    private val target: View,
    private val buffer: Editable,
    private val modifiers: () -> Int,
    private val text: (String) -> Unit,
    private val key: (Int) -> Unit,
    private val clipboard: (Int) -> Boolean,
) : BaseInputConnection(target, true) {
    override fun getEditable(): Editable = buffer

    override fun performContextMenuAction(id: Int): Boolean =
        clipboard(id) || super.performContextMenuAction(id)

    private fun commit(value: String) {
        ScreenKeyboard.committed(value, modifiers()).forEach { typed ->
            when (typed) {
                is Typed.Key -> key(typed.hid)
                is Typed.Text -> text(typed.text)
            }
        }
    }

    override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
        text?.let { commit(it.toString()) }
        buffer.clear()
        return true
    }

    override fun finishComposingText(): Boolean {
        if (buffer.isNotEmpty()) {
            commit(buffer.toString())
            buffer.clear()
        }
        return super.finishComposingText()
    }

    override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
        if (buffer.isNotEmpty()) return super.deleteSurroundingText(beforeLength, afterLength)
        repeat(beforeLength.coerceIn(0, 128)) { key(ScreenKeyboard.BACKSPACE) }
        repeat(afterLength.coerceIn(0, 128)) { key(ScreenKeyboard.DELETE) }
        return true
    }

    override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int) =
        deleteSurroundingText(beforeLength, afterLength)

    override fun sendKeyEvent(event: KeyEvent): Boolean {
        if (
            event.action == KeyEvent.ACTION_DOWN &&
                event.keyCode in setOf(KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER)
        )
            finishComposingText()
        return target.dispatchKeyEvent(event)
    }

    override fun performEditorAction(actionCode: Int): Boolean {
        // An action may arrive while an IME still owns composed characters.
        finishComposingText()
        key(ScreenKeyboard.ENTER)
        return true
    }
}
