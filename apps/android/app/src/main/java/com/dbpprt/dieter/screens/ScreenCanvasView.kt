package com.dbpprt.dieter.screens

import android.content.Context
import android.graphics.*
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.view.*
import android.view.inputmethod.*
import android.widget.FrameLayout
import com.dbpprt.dieter.v1.RemoteDesktopCursor
import com.dbpprt.dieter.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.v1.RemoteDesktopRenderMeasurement
import org.webrtc.*
import java.util.concurrent.CountDownLatch
import kotlin.math.*

/** A GPU-backed desktop canvas with a relative touchpad above it. */
class ScreenCanvasView(context: Context, val controller: ScreenController) : FrameLayout(context) {
    val canvasModel = controller.canvasModel
    private val texture = TextureView(context)
    private val direct = controller.directSurfacePresentation
    private val surface = if (controller.surfacePresentation || direct) SurfaceView(context) else null
    private val videoView: View get() = if (direct) texture else surface ?: texture
    private val directCover = View(context).apply { setBackgroundColor(Color.rgb(12, 15, 20)) }
    private var decoderSurface: DecoderSurface? = null
    private val directLock = Any()
    private var pendingDirect: Pair<VideoFrame, Long>? = null
    private var directPosted = false
    internal fun isVisibleVideoSurface(view: SurfaceView): Boolean = surface === view && view.isShown &&
        (!direct || (texture.alpha == 0f && directCover.visibility != VISIBLE))
    private data class Viewport(val x: Int, val y: Int, val width: Int, val height: Int)
    @Volatile private var viewport = Viewport(0, 0, 1, 1)
    private val sink: (VideoFrame, Long) -> Unit = { frame, token -> onFrame(frame, token) }
    private val cursorListener: (RemoteDesktopCursor) -> Unit = { updateCursor(it) }
    private val resetListener: () -> Unit = { clearFrame() }
    private var drawnTimestamp = 0L
    private var drawnSession = -1L
    private var drawnArrival = 0L
    private val frameSessions = LinkedHashMap<Long, Pair<Long, Long>>()
    private var drawnWidth = 1
    private var drawnHeight = 1
    private val renderer = EglRenderer("DieterScreen", object : VideoFrameDrawer() {
        override fun drawFrame(frame: VideoFrame, drawer: RendererCommon.GlDrawer, matrix: Matrix?, x: Int, y: Int, width: Int, height: Int) {
            if (surface == null || direct) super.drawFrame(frame, drawer, matrix, x, y, width, height)
            else viewport.let { super.drawFrame(frame, drawer, matrix, it.x, it.y, it.width, it.height) }
            drawnTimestamp = frame.timestampNs
            val metadata = synchronized(frameSessions) { frameSessions.remove(frame.timestampNs) }
            drawnSession = metadata?.first ?: -1L; drawnArrival = metadata?.second ?: System.nanoTime()
            drawnWidth = frame.rotatedWidth; drawnHeight = frame.rotatedHeight
        }
    })
    private var initialized = false
    @Volatile private var released = false
    @Volatile private var paused = false
    @Volatile private var visibleSession = -1L
    private var frameWidth = 1600
    private var frameHeight = 900
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val cursorShapes = LinkedHashMap<String, Bitmap>()
    private var cursorBitmap: Bitmap? = null
    private var cursor = RemoteDesktopCursor.getDefaultInstance()
    private var lastLocalMove = 0L
    private var downTime = 0L
    private var lastTap = 0L
    private var previousX = 0f
    private var previousY = 0f
    private var previousSpan = 0f
    private var downX = 0f
    private var downY = 0f
    private var fingers = 0
    private var maxFingers = 0
    private var moved = false
    private var dragging = false
    private var scrolling = false
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    var modifiers = 0
    private val longPress = Runnable {
        if (fingers == 1 && maxFingers == 1 && !moved && controller.state.value.control) {
            dragging = true; moved = true
            button(Button.BUTTON_LEFT, true)
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    }
    private val editorBuffer = Editable.Factory.getInstance().newEditable("")

    init {
        setBackgroundColor(Color.rgb(12, 15, 20))
        isFocusable = true; isFocusableInTouchMode = true; keepScreenOn = true
        contentDescription = "Remote screen. One finger moves the cursor; tap clicks; hold and move drags. Two fingers zoom and pan. Three fingers scroll."
        if (direct) {
            surface?.tag = "dieter-direct-output"
            addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            addView(texture, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
            addView(directCover, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        } else addView(videoView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        setWillNotDraw(false)
        renderer.init(controller.egl.eglBaseContext, EglBase.CONFIG_PLAIN, GlRectDrawer())
        initialized = true
        renderer.addRenderListener { submittedAt ->
            val timestamp = drawnTimestamp; val w = drawnWidth; val h = drawnHeight
            controller.presented(timestamp, drawnSession, (submittedAt - drawnArrival).coerceAtLeast(0) / 1_000_000.0)
            if (direct) {
                val session = drawnSession
                post { if (!released && controller.acceptsFrame(session)) { texture.alpha = 1f; directCover.visibility = GONE } }
            }
            if (w != frameWidth || h != frameHeight) post {
                if (!released) { frameWidth = w; frameHeight = h; geometry() }
            }
        }
        texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                if (!released) { renderer.createEglSurface(surface); geometry(); controller.configure(refresh = true) }
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = geometry()
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                val latch = CountDownLatch(1)
                if (initialized) { renderer.releaseEglSurface { latch.countDown() }; latch.await() }
                return true
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }
        surface?.holder?.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (!released) {
                    if (direct) {
                        lateinit var target: DecoderSurface
                        target = DecoderSurface(holder.surface) { timestamp, decodedAt, _, renderedAt, _, _ ->
                            val metadata = synchronized(frameSessions) { frameSessions.remove(timestamp) }
                            if (!released && decoderSurface === target && metadata != null && controller.acceptsFrame(metadata.first)) {
                                texture.alpha = 0f; directCover.visibility = GONE
                                controller.presented(timestamp, metadata.first,
                                    (renderedAt - decodedAt).coerceAtLeast(0) / 1_000_000.0,
                                    RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED)
                            }
                        }
                        decoderSurface = target
                        controller.attachDecoderSurface(target)
                    } else renderer.createEglSurface(holder.surface)
                    geometry(); controller.configure(refresh = true)
                }
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = geometry()
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (direct) {
                    clearPendingDirect()
                    decoderSurface?.let(controller::detachDecoderSurface)
                    decoderSurface = null
                    texture.alpha = 1f; directCover.visibility = VISIBLE
                    return
                }
                // SurfaceHolder owns the Surface. Finish all old EGL use before
                // returning ownership; never release the holder's Surface here.
                val latch = CountDownLatch(1)
                if (initialized) { renderer.releaseEglSurface { latch.countDown() }; latch.await() }
            }
        })
        controller.videoSink = sink
        controller.onCursor = cursorListener
        controller.onVideoReset = resetListener
    }
    private fun onFrame(frame: VideoFrame, token: Long) {
        if (released || !controller.acceptsFrame(token)) return
        if (frame.buffer is VideoFrame.SurfaceBuffer) {
            // One latest decoded buffer may wait for the UI transform. The SDK
            // separately caps actual codec output ownership and fences reuse.
            synchronized(directLock) {
                frame.retain()
                pendingDirect?.first?.release()
                pendingDirect = frame to token
                if (!directPosted) { directPosted = true; post(::renderDirect) }
            }
            return
        }
        if (visibleSession != token) {
            visibleSession = token
            post { if (!released && controller.acceptsFrame(token)) videoView.visibility = VISIBLE }
        }
        synchronized(frameSessions) {
            if (frameSessions.size >= 8) frameSessions.remove(frameSessions.keys.first())
            frameSessions[frame.timestampNs] = token to System.nanoTime()
        }
        if (paused) { paused = false; renderer.disableFpsReduction() }
        renderer.onFrame(frame)
    }
    private fun renderDirect() {
        val pending = synchronized(directLock) { directPosted = false; pendingDirect.also { pendingDirect = null } } ?: return
        val (frame, session) = pending
        try {
            if (released || !controller.acceptsFrame(session)) return
            if (frame.rotation != 0) {
                // Surface layout handles canvas transforms, not per-frame
                // rotation. Closing the optional target forces texture fallback.
                decoderSurface?.close(); controller.resumeConnection(); return
            }
            if (frameWidth != frame.rotatedWidth || frameHeight != frame.rotatedHeight) {
                frameWidth = frame.rotatedWidth; frameHeight = frame.rotatedHeight; geometry()
            }
            synchronized(frameSessions) {
                if (frameSessions.size >= 32) frameSessions.remove(frameSessions.keys.first())
                frameSessions[frame.timestampNs] = session to System.nanoTime()
            }
            val displayed = runCatching { (frame.buffer as VideoFrame.SurfaceBuffer).render() }.getOrElse {
                decoderSurface?.close(); controller.resumeConnection(); false
            }
            if (!displayed) synchronized(frameSessions) { frameSessions.remove(frame.timestampNs) }
        } finally { frame.release() }
    }
    private fun clearPendingDirect() {
        synchronized(directLock) { pendingDirect?.first?.release(); pendingDirect = null }
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { super.onSizeChanged(w, h, oldw, oldh); geometry() }
    private fun geometry() {
        canvasModel.resize(width, height, frameWidth, frameHeight)
        applyCanvasTransform()
    }
    private fun applyCanvasTransform() {
        val m = canvasModel
        // SurfaceView avoids TextureView composition but still uses the same
        // EGL texture decoder. Clip an explicit GL viewport, without allocating
        // a zoom-sized Surface or changing input/cursor coordinates.
        viewport = Viewport(m.left.roundToInt(), (height - m.top - m.remoteHeight * m.scale).roundToInt(),
            (m.remoteWidth * m.scale).roundToInt().coerceAtLeast(1), (m.remoteHeight * m.scale).roundToInt().coerceAtLeast(1))
        // TextureView is the viewport; transform its content into the remote aspect and canvas bounds.
        texture.setTransform(Matrix().apply {
            setScale(m.remoteWidth * m.scale / width.coerceAtLeast(1), m.remoteHeight * m.scale / height.coerceAtLeast(1))
            postTranslate(m.left, m.top)
        })
        if (direct) surface?.let {
            // Fixed decoder-sized storage; zoom only changes compositor geometry.
            // Allocating a zoom-sized buffer would multiply bandwidth and memory.
            it.holder.setFixedSize(frameWidth, frameHeight)
            it.layoutParams = LayoutParams(
                (m.remoteWidth * m.scale).roundToInt().coerceAtLeast(1),
                (m.remoteHeight * m.scale).roundToInt().coerceAtLeast(1)).apply {
                leftMargin = m.left.roundToInt(); topMargin = m.top.roundToInt()
            }
        }
        invalidate()
    }
    fun resetCanvas() { canvasModel.reset(); applyCanvasTransform() }
    fun clearFrame() {
        if (released) return
        visibleSession = -1L
        if (direct) { directCover.visibility = VISIBLE; texture.alpha = 1f; clearPendingDirect() }
        else videoView.visibility = INVISIBLE
        synchronized(frameSessions) { frameSessions.clear() }
        paused = true; renderer.pauseVideo()
        renderer.clearImage(12 / 255f, 15 / 255f, 20 / 255f, 1f)
        cursorShapes.clear(); cursorBitmap = null; invalidate()
    }
    fun release() {
        if (released) return
        cancelGesture(); controller.releaseInput()
        if (controller.onCursor === cursorListener) controller.onCursor = null
        if (controller.videoSink === sink) controller.videoSink = null
        if (controller.onVideoReset === resetListener) controller.onVideoReset = null
        released = true; initialized = false
        clearPendingDirect()
        decoderSurface?.let(controller::detachDecoderSurface); decoderSurface = null
        renderer.release(); cursorShapes.clear(); cursorBitmap = null
    }
    private fun updateCursor(value: RemoteDesktopCursor) {
        val changedDisplay = cursor.displayGeneration != value.displayGeneration
        cursor = value
        if (!value.png.isEmpty && value.png.size() <= 262144 && value.width in 1.0..256.0 && value.height in 1.0..256.0) {
            val raw = value.png.toByteArray()
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
            if (bounds.outWidth in 1..512 && bounds.outHeight in 1..512) {
                BitmapFactory.decodeByteArray(raw, 0, raw.size)?.let { bitmap ->
                    if (cursorShapes.size >= 32) cursorShapes.clear()
                    cursorShapes[value.shapeId] = bitmap
                }
            }
        }
        cursorBitmap = cursorShapes[value.shapeId]
        if (changedDisplay || (value.lastInputOrdinal >= controller.lastPointerOrdinal && SystemClock.uptimeMillis() - lastLocalMove > 100)) {
            canvasModel.cursor(value.normalizedX / 1_000_000f, value.normalizedY / 1_000_000f)
        }
        invalidate()
    }
    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (controller.state.value.phase != "streaming") return
        val m = canvasModel
        val x = m.left + m.cursorX * m.remoteWidth * m.scale
        val y = m.top + m.cursorY * m.remoteHeight * m.scale
        val bitmap = cursorBitmap
        // Keep the pointer legible on a phone, independent of desktop resolution.
        val size = max(resources.displayMetrics.density, m.scale)
        if (bitmap != null && cursor.visible) {
            val left = x - cursor.hotspotX.toFloat() * size; val top = y - cursor.hotspotY.toFloat() * size
            canvas.drawBitmap(bitmap, null, RectF(left, top, left + cursor.width.toFloat() * size, top + cursor.height.toFloat() * size), paint)
        } else {
            val path = Path().apply { moveTo(x, y); lineTo(x + 5 * size, y + 18 * size); lineTo(x + 9 * size, y + 12 * size); lineTo(x + 16 * size, y + 10 * size); close() }
            paint.style = Paint.Style.FILL; paint.color = Color.WHITE; canvas.drawPath(path, paint)
            paint.style = Paint.Style.STROKE; paint.strokeWidth = size; paint.color = Color.BLACK; canvas.drawPath(path, paint); paint.style = Paint.Style.FILL
        }
    }
    private fun button(which: Button, down: Boolean, count: Int = 1) = controller.button(which, down, canvasModel.cursorX, canvasModel.cursorY, count, modifiers)
    fun click(which: Button = Button.BUTTON_LEFT) { button(which, true); button(which, false); super.performClick() }
    override fun performClick(): Boolean { button(Button.BUTTON_LEFT, true); button(Button.BUTTON_LEFT, false); super.performClick(); return true }
    private fun cancelGesture() {
        removeCallbacks(longPress)
        if (dragging) button(Button.BUTTON_LEFT, false)
        if (scrolling) controller.scroll(0f, 0f, 4)
        dragging = false; scrolling = false; fingers = 0; maxFingers = 0; previousSpan = 0f
    }
    private fun rebasePointers(event: MotionEvent, excluding: Int = -1) {
        val active = (0 until event.pointerCount).filter { it != excluding }
        fingers = active.size
        if (active.isEmpty()) { previousSpan = 0f; return }
        previousX = active.sumOf { event.getX(it).toDouble() }.toFloat() / fingers
        previousY = active.sumOf { event.getY(it).toDouble() }.toFloat() / fingers
        previousSpan = if (fingers == 2) hypot(event.getX(active[1]) - event.getX(active[0]),
            event.getY(active[1]) - event.getY(active[0])) else 0f
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) return mouse(event)
        parent?.requestDisallowInterceptTouchEvent(true)
        val count = event.pointerCount
        val cx = (0 until count).sumOf { event.getX(it).toDouble() }.toFloat() / count
        val cy = (0 until count).sumOf { event.getY(it).toDouble() }.toFloat() / count
        val span = if (count == 2) hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0)) else 0f
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestFocus(); cancelGesture(); downTime = event.eventTime; fingers = 1; maxFingers = 1; moved = false
                downX = cx; downY = cy; previousX = cx; previousY = cy
                postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                removeCallbacks(longPress)
                if (dragging) { button(Button.BUTTON_LEFT, false); dragging = false }
                if (scrolling) { controller.scroll(0f, 0f, 4); scrolling = false }
                fingers = count; maxFingers = max(maxFingers, count); moved = true
                if (count == 3 && maxFingers == 3) { controller.scroll(0f, 0f, 1); scrolling = true }
                rebasePointers(event)
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = cx - previousX; val dy = cy - previousY
                if (hypot(cx - downX, cy - downY) > slop) { moved = true; removeCallbacks(longPress) }
                when {
                    count == 1 && maxFingers == 1 -> {
                        canvasModel.move(dx, dy); controller.pointer(canvasModel.cursorX, canvasModel.cursorY)
                        lastLocalMove = event.eventTime; applyCanvasTransform()
                    }
                    count == 2 && maxFingers == 2 -> {
                        val factor = if (previousSpan > 1f && span > 1f) span / previousSpan else 1f
                        canvasModel.transform(factor, previousX, previousY, cx, cy); applyCanvasTransform()
                    }
                    count == 3 && maxFingers == 3 -> controller.scroll(dx / resources.displayMetrics.density, dy / resources.displayMetrics.density, 2)
                }
                previousX = cx; previousY = cy; previousSpan = span
            }
            MotionEvent.ACTION_POINTER_UP -> {
                removeCallbacks(longPress)
                if (scrolling) { controller.scroll(0f, 0f, 4); scrolling = false }
                // Rebase around the remaining pointer IDs so replacing one
                // finger can continue the canvas gesture without a jump.
                // maxFingers still prevents an accidental one-finger mouse move/click.
                rebasePointers(event, event.actionIndex)
            }
            MotionEvent.ACTION_UP -> {
                if (maxFingers == 1 && !moved && !dragging && event.eventTime - downTime < ViewConfiguration.getLongPressTimeout()) {
                    val clicks = if (event.eventTime - lastTap < ViewConfiguration.getDoubleTapTimeout()) 2 else 1
                    button(Button.BUTTON_LEFT, true, clicks); button(Button.BUTTON_LEFT, false, clicks)
                    lastTap = if (clicks == 2) 0 else event.eventTime; super.performClick()
                }
                cancelGesture()
            }
            MotionEvent.ACTION_CANCEL -> { cancelGesture(); controller.releaseInput() }
        }
        return true
    }
    private fun mouse(event: MotionEvent): Boolean {
        val m = canvasModel
        m.cursor((event.x - m.left) / (m.remoteWidth * m.scale), (event.y - m.top) / (m.remoteHeight * m.scale))
        controller.pointer(m.cursorX, m.cursorY); lastLocalMove = event.eventTime; invalidate()
        val which = if (event.buttonState and MotionEvent.BUTTON_SECONDARY != 0 || event.actionButton == MotionEvent.BUTTON_SECONDARY) Button.BUTTON_RIGHT else Button.BUTTON_LEFT
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_BUTTON_PRESS -> button(which, true)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_BUTTON_RELEASE -> button(which, false)
            MotionEvent.ACTION_SCROLL -> controller.scroll(event.getAxisValue(MotionEvent.AXIS_HSCROLL) * 40, event.getAxisValue(MotionEvent.AXIS_VSCROLL) * 40, 0)
        }
        return true
    }
    override fun onGenericMotionEvent(event: MotionEvent): Boolean =
        if (event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) mouse(event) else super.onGenericMotionEvent(event)
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) { cancelGesture(); editorBuffer.clear(); modifiers = 0 }
        controller.focus(hasWindowFocus)
    }
    fun showKeyboard(show: Boolean) {
        requestFocus()
        val ime = context.getSystemService(InputMethodManager::class.java)
        if (show) ime.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        else { ime.hideSoftInputFromWindow(windowToken, 0); editorBuffer.clear(); controller.releaseInput() }
    }
    override fun onCheckIsTextEditor() = true
    override fun onCreateInputConnection(info: EditorInfo): InputConnection {
        info.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        info.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        return object : BaseInputConnection(this, true) {
            override fun getEditable(): Editable = editorBuffer
            override fun performContextMenuAction(id: Int): Boolean = when (id) {
                android.R.id.paste -> { controller.clipboard.paste(); true }
                android.R.id.cut -> { controller.clipboard.perform(com.dbpprt.dieter.v1.RemoteDesktopClipboardRequest.Action.CUT); true }
                android.R.id.copy -> { controller.clipboard.copy(); true }
                else -> super.performContextMenuAction(id)
            }
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                text?.let { committedText(it.toString()) }; editorBuffer.clear(); return true
            }
            override fun finishComposingText(): Boolean {
                if (editorBuffer.isNotEmpty()) { committedText(editorBuffer.toString()); editorBuffer.clear() }
                return super.finishComposingText()
            }
            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (editorBuffer.isNotEmpty()) return super.deleteSurroundingText(beforeLength, afterLength)
                repeat(beforeLength.coerceIn(0, 128)) { pressKey(42) }; repeat(afterLength.coerceIn(0, 128)) { pressKey(76) }; return true
            }
            override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int) = deleteSurroundingText(beforeLength, afterLength)
            override fun sendKeyEvent(event: KeyEvent) = dispatchKeyEvent(event)
            override fun performEditorAction(actionCode: Int): Boolean { pressKey(40); return true }
        }
    }
    private fun committedText(value: String) {
        if (modifiers and 14 == 0) { controller.text(value); return }
        // IMEs commit text rather than KeyEvents. Armed shortcut modifiers still
        // need physical HID keys, otherwise Cmd+A would type a literal "a".
        for (character in value) {
            val hid = when (val lower = character.lowercaseChar()) {
                in 'a'..'z' -> lower - 'a' + 4
                in '1'..'9' -> lower - '1' + 30
                '0' -> 39
                ' ' -> 44
                else -> null
            }
            if (hid != null) pressKey(hid) else controller.text(character.toString())
        }
    }
    fun pressKey(hid: Int) { controller.key(hid, true, modifiers); controller.key(hid, false, modifiers) }
    override fun onKeyDown(code: Int, event: KeyEvent): Boolean {
        val hid = ScreenKeys.hid(code)
        if (hid != null) { controller.key(hid, true, modifiers or ScreenKeys.modifiers(event), event.repeatCount > 0); return true }
        if (event.unicodeChar > 0) { controller.text(String(Character.toChars(event.unicodeChar))); return true }
        return super.onKeyDown(code, event)
    }
    override fun onKeyUp(code: Int, event: KeyEvent): Boolean {
        val hid = ScreenKeys.hid(code) ?: return super.onKeyUp(code, event)
        controller.key(hid, false, modifiers or ScreenKeys.modifiers(event)); return true
    }
}

internal object ScreenKeys {
    fun modifiers(event: KeyEvent) = (if (event.isShiftPressed) 1 else 0) or (if (event.isCtrlPressed) 2 else 0) or
        (if (event.isAltPressed) 4 else 0) or (if (event.isMetaPressed) 8 else 0)
    fun hid(code: Int): Int? = when (code) {
        in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> code - KeyEvent.KEYCODE_A + 4
        in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_9 -> code - KeyEvent.KEYCODE_1 + 30
        KeyEvent.KEYCODE_0 -> 39
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> code - KeyEvent.KEYCODE_F1 + 58
        else -> mapOf(KeyEvent.KEYCODE_ENTER to 40, KeyEvent.KEYCODE_ESCAPE to 41, KeyEvent.KEYCODE_DEL to 42,
            KeyEvent.KEYCODE_TAB to 43, KeyEvent.KEYCODE_SPACE to 44, KeyEvent.KEYCODE_MINUS to 45, KeyEvent.KEYCODE_EQUALS to 46,
            KeyEvent.KEYCODE_LEFT_BRACKET to 47, KeyEvent.KEYCODE_RIGHT_BRACKET to 48, KeyEvent.KEYCODE_BACKSLASH to 49,
            KeyEvent.KEYCODE_SEMICOLON to 51, KeyEvent.KEYCODE_APOSTROPHE to 52, KeyEvent.KEYCODE_GRAVE to 53,
            KeyEvent.KEYCODE_COMMA to 54, KeyEvent.KEYCODE_PERIOD to 55, KeyEvent.KEYCODE_SLASH to 56,
            KeyEvent.KEYCODE_CAPS_LOCK to 57, KeyEvent.KEYCODE_INSERT to 73, KeyEvent.KEYCODE_MOVE_HOME to 74,
            KeyEvent.KEYCODE_PAGE_UP to 75, KeyEvent.KEYCODE_FORWARD_DEL to 76, KeyEvent.KEYCODE_MOVE_END to 77,
            KeyEvent.KEYCODE_PAGE_DOWN to 78, KeyEvent.KEYCODE_DPAD_RIGHT to 79, KeyEvent.KEYCODE_DPAD_LEFT to 80,
            KeyEvent.KEYCODE_DPAD_DOWN to 81, KeyEvent.KEYCODE_DPAD_UP to 82,
            KeyEvent.KEYCODE_CTRL_LEFT to 224, KeyEvent.KEYCODE_SHIFT_LEFT to 225, KeyEvent.KEYCODE_ALT_LEFT to 226,
            KeyEvent.KEYCODE_META_LEFT to 227, KeyEvent.KEYCODE_CTRL_RIGHT to 228, KeyEvent.KEYCODE_SHIFT_RIGHT to 229,
            KeyEvent.KEYCODE_ALT_RIGHT to 230, KeyEvent.KEYCODE_META_RIGHT to 231)[code]
    }
}
