package com.dbpprt.dieter.screens

import android.text.Editable
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.screens.AndroidKeys
import org.junit.Assert.assertEquals
import org.junit.Test

class ScreenInputConnectionTest {
    @Test fun androidImeReturnCompositionAndHardwareKeysReachExistingInputOperations() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val sent = mutableListOf<String>()
            val target = object : View(instrumentation.targetContext) {
                override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                    sent += "${AndroidKeys.hid(event.keyCode)}:${event.action}"
                    return true
                }
            }
            val connection = ScreenInputConnection(target, Editable.Factory.getInstance().newEditable(""), { 0 },
                { sent += "text:$it" }, { sent += "key:$it" }, { false })
            connection.setComposingText("draft", 1)
            connection.commitText("é世界🙂", 1)
            connection.finishComposingText()
            connection.commitText("\n", 1)
            connection.commitText("one\r\ntwo\n", 1)
            connection.setComposingText("composed", 1)
            connection.performEditorAction(EditorInfo.IME_ACTION_DONE)
            connection.deleteSurroundingText(1, 1)
            connection.setComposingText("return", 1)
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_NUMPAD_ENTER))
            connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_NUMPAD_ENTER))
            assertEquals(listOf("text:é世界🙂", "key:40", "text:one", "key:40", "text:two", "key:40",
                "text:composed", "key:40", "key:42", "key:76", "text:return", "40:0", "40:1", "88:0", "88:1"), sent)
        }
    }
}
