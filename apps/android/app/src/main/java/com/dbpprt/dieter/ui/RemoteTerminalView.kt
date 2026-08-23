package com.dbpprt.dieter.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.text.InputType
import android.text.SpannableStringBuilder
import android.util.TypedValue
import android.view.GestureDetector
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalRenderer
import kotlin.math.abs
import kotlin.math.max

/**
 * A native, remote-only terminal surface. Termux supplies the ANSI/VT emulator
 * and glyph renderer; all process ownership and I/O remain in the Dieter daemon.
 */
class RemoteTerminalView(context: Context) : android.view.View(context) {
    var onInput: (ByteArray) -> Unit = {}
    var onResize: (columns: Int, rows: Int) -> Unit = { _, _ -> }
    var onControlChanged: (Boolean) -> Unit = {}

    private val renderer = TerminalRenderer(
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 13f, resources.displayMetrics).toInt(),
        Typeface.MONOSPACE,
    )
    private var consumedBytes = 0
    private var appliedResetRevision = Long.MIN_VALUE
    private var topRow = 0
    private var controlArmed = false
    @Volatile private var cursorBlinkVisible = true
    @Volatile private var cursorBlinkTransitions = 0
    private var cursorBlinkRunning = false
    private val horizontalInset = (10f * resources.displayMetrics.density).toInt()
    private val verticalInset = (8f * resources.displayMetrics.density).toInt()

    private val cursorBlinkRunnable = object : Runnable {
        override fun run() {
            if (!cursorBlinkRunning) return
            cursorBlinkVisible = !cursorBlinkVisible
            cursorBlinkTransitions += 1
            emulator.setCursorBlinkState(cursorBlinkVisible)
            postInvalidateOnAnimation()
            postDelayed(this, CURSOR_BLINK_INTERVAL_MILLIS)
        }
    }

    private val output = object : TerminalOutput() {
        override fun write(data: ByteArray, offset: Int, count: Int) {
            if (count > 0) onInput(data.copyOfRange(offset, offset + count))
        }

        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit

        override fun onCopyTextToClipboard(text: String?) {
            text?.takeIf(String::isNotEmpty)?.let(::copyText)
        }

        override fun onPasteTextFromClipboard() = pasteClipboard()

        override fun onBell() {
            performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        }

        override fun onColorsChanged() = postInvalidateOnAnimation()
    }

    private val sessionClient = object : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession?) = postInvalidateOnAnimation()
        override fun onTitleChanged(changedSession: TerminalSession?) = Unit
        override fun onSessionFinished(finishedSession: TerminalSession?) = Unit
        override fun onCopyTextToClipboard(session: TerminalSession?, text: String?) = output.onCopyTextToClipboard(text)
        override fun onPasteTextFromClipboard(session: TerminalSession?) = pasteClipboard()
        override fun onBell(session: TerminalSession?) = output.onBell()
        override fun onColorsChanged(session: TerminalSession?) = postInvalidateOnAnimation()
        override fun onTerminalCursorStateChange(state: Boolean) = postInvalidateOnAnimation()
        override fun getTerminalCursorStyle(): Int? = TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK
        override fun logError(tag: String?, message: String?) = Unit
        override fun logWarn(tag: String?, message: String?) = Unit
        override fun logInfo(tag: String?, message: String?) = Unit
        override fun logDebug(tag: String?, message: String?) = Unit
        override fun logVerbose(tag: String?, message: String?) = Unit
        override fun logStackTraceWithMessage(tag: String?, message: String?, exception: Exception?) = Unit
        override fun logStackTrace(tag: String?, exception: Exception?) = Unit
    }

    private val emulator = TerminalEmulator(
        output,
        80,
        28,
        renderer.fontWidth.toInt().coerceAtLeast(1),
        renderer.fontLineSpacing.coerceAtLeast(1),
        10_000,
        sessionClient,
    ).apply {
        mColors.mCurrentColors[TextStyle.COLOR_INDEX_FOREGROUND] = Color.rgb(236, 239, 244)
        mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND] = Color.rgb(8, 9, 13)
        mColors.mCurrentColors[TextStyle.COLOR_INDEX_CURSOR] = Color.rgb(182, 173, 246)
        setCursorBlinkingEnabled(true)
        setCursorBlinkState(true)
    }

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(event: MotionEvent): Boolean = true

        override fun onSingleTapUp(event: MotionEvent): Boolean {
            requestFocus()
            showKeyboard()
            return true
        }

        override fun onScroll(
            first: MotionEvent?,
            current: MotionEvent,
            distanceX: Float,
            distanceY: Float,
        ): Boolean {
            if (abs(distanceY) < abs(distanceX)) return false
            val lines = max(1, (abs(distanceY) / renderer.fontLineSpacing).toInt())
            val transcriptRows = emulator.screen.activeTranscriptRows
            topRow = if (distanceY > 0) {
                (topRow - lines).coerceAtLeast(-transcriptRows)
            } else {
                (topRow + lines).coerceAtMost(0)
            }
            invalidate()
            return true
        }

        override fun onLongPress(event: MotionEvent) {
            val text = emulator.screen.transcriptText.trimEnd()
            if (text.isNotEmpty()) {
                copyText(text)
                Toast.makeText(context, "Terminal output copied", Toast.LENGTH_SHORT).show()
                performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            }
        }
    })

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setBackgroundColor(Color.rgb(8, 9, 13))
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        contentDescription = "Interactive remote terminal"
    }

    fun applyScreen(screen: TerminalScreenState) {
        var changed = false
        if (appliedResetRevision != screen.resetRevision || consumedBytes > screen.data.size) {
            emulator.reset()
            consumedBytes = 0
            appliedResetRevision = screen.resetRevision
            topRow = 0
            changed = true
        }
        if (screen.data.size > consumedBytes) {
            val suffix = screen.data.copyOfRange(consumedBytes, screen.data.size)
            emulator.append(suffix, suffix.size)
            consumedBytes = screen.data.size
            if (topRow == 0) emulator.clearScrollCounter()
            changed = true
        }
        if (changed) revealCursorAndRestartBlink() else postInvalidateOnAnimation()
    }

    fun toggleControl() {
        controlArmed = !controlArmed
        onControlChanged(controlArmed)
        requestFocus()
        showKeyboard()
    }

    fun sendKeyCode(keyCode: Int) {
        val modifiers = if (consumeControl()) KeyHandler.KEYMOD_CTRL else 0
        val sequence = KeyHandler.getCode(
            keyCode,
            modifiers,
            emulator.isCursorKeysApplicationMode,
            emulator.isKeypadApplicationMode,
        ) ?: return
        sendText(sequence, applyControl = false)
    }

    fun sendBytes(bytes: ByteArray) {
        consumeControl()
        if (bytes.isNotEmpty()) onInput(bytes)
        revealCursorAndRestartBlink()
        requestFocus()
    }

    fun pasteClipboard() {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
        if (text.isNotEmpty()) {
            emulator.paste(text)
            revealCursorAndRestartBlink()
        }
    }

    internal fun transcriptForTesting(): String = emulator.screen.transcriptText
    internal fun cursorVisibleForTesting(): Boolean = emulator.shouldCursorBeVisible()
    internal fun cursorBlinkTransitionsForTesting(): Int = cursorBlinkTransitions

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.save()
        canvas.translate(horizontalInset.toFloat(), verticalInset.toFloat())
        renderer.render(emulator, canvas, topRow, -1, -1, -1, -1)
        canvas.restore()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        val columns = ((width - horizontalInset * 2) / renderer.fontWidth).toInt().coerceIn(2, 500)
        val rows = ((height - verticalInset * 2) / renderer.fontLineSpacing).coerceIn(2, 500)
        if (columns != emulator.mColumns || rows != emulator.mRows) {
            emulator.resize(columns, rows, renderer.fontWidth.toInt().coerceAtLeast(1), renderer.fontLineSpacing)
            onResize(columns, rows)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        startCursorBlinking()
    }

    override fun onDetachedFromWindow() {
        stopCursorBlinking()
        super.onDetachedFromWindow()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        if (isVisible) startCursorBlinking() else stopCursorBlinking()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = gestures.onTouchEvent(event) || super.onTouchEvent(event)

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        return object : BaseInputConnection(this, false) {
            private val editable = SpannableStringBuilder()

            override fun getEditable() = editable

            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                text?.toString()?.takeIf(String::isNotEmpty)?.let { sendText(it) }
                editable.clear()
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                editable.clear()
                if (text != null) editable.append(text)
                return true
            }

            override fun finishComposingText(): Boolean {
                if (editable.isNotEmpty()) sendText(editable.toString())
                editable.clear()
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtMost(64)) { onInput(byteArrayOf(0x7f)) }
                if (beforeLength > 0) revealCursorAndRestartBlink()
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean = this@RemoteTerminalView.dispatchKeyEvent(event)
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val special = KeyHandler.getCode(
            keyCode,
            keyModifiers(event),
            emulator.isCursorKeysApplicationMode,
            emulator.isKeypadApplicationMode,
        )
        if (special != null) {
            sendText(special, applyControl = false)
            consumeControl()
            return true
        }
        val unicode = event.getUnicodeChar(event.metaState and KeyEvent.META_CTRL_MASK.inv())
        if (unicode > 0) {
            val text = String(Character.toChars(unicode))
            sendText(text, applyControl = event.isCtrlPressed || controlArmed)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun keyModifiers(event: KeyEvent): Int {
        var modifiers = 0
        if (event.isCtrlPressed || controlArmed) modifiers = modifiers or KeyHandler.KEYMOD_CTRL
        if (event.isAltPressed) modifiers = modifiers or KeyHandler.KEYMOD_ALT
        if (event.isShiftPressed) modifiers = modifiers or KeyHandler.KEYMOD_SHIFT
        return modifiers
    }

    private fun sendText(value: String, applyControl: Boolean = controlArmed) {
        val transformed = if (applyControl && value.length == 1) {
            val character = value[0]
            when (character) {
                in '@'..'_' -> (character.code - 64).toChar().toString()
                in 'a'..'z' -> (character.code - 96).toChar().toString()
                '?' -> 0x7f.toChar().toString()
                else -> value
            }
        } else value
        onInput(transformed.toByteArray(Charsets.UTF_8))
        revealCursorAndRestartBlink()
        if (applyControl) consumeControl()
    }

    private fun startCursorBlinking() {
        if (cursorBlinkRunning || !isAttachedToWindow || !isShown) return
        cursorBlinkRunning = true
        revealCursorAndRestartBlink()
    }

    private fun stopCursorBlinking() {
        cursorBlinkRunning = false
        removeCallbacks(cursorBlinkRunnable)
        cursorBlinkVisible = true
        emulator.setCursorBlinkState(true)
    }

    private fun revealCursorAndRestartBlink() {
        cursorBlinkVisible = true
        emulator.setCursorBlinkState(true)
        removeCallbacks(cursorBlinkRunnable)
        if (cursorBlinkRunning) postDelayed(cursorBlinkRunnable, CURSOR_BLINK_INTERVAL_MILLIS)
        postInvalidateOnAnimation()
    }

    private fun consumeControl(): Boolean {
        val wasArmed = controlArmed
        if (wasArmed) {
            controlArmed = false
            onControlChanged(false)
        }
        return wasArmed
    }

    private fun showKeyboard() {
        post {
            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                .showSoftInput(this, 0)
        }
    }

    private fun copyText(text: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Terminal output", text))
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.S_V2) {
            Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
        }
    }

    private companion object {
        const val CURSOR_BLINK_INTERVAL_MILLIS = 600L
    }
}
