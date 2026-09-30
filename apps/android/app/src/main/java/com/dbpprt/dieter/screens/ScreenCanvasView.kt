package com.dbpprt.dieter.screens

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.*
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.view.*
import android.view.animation.DecelerateInterpolator
import android.view.inputmethod.*
import android.widget.FrameLayout
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.core.screens.AndroidKeys
import com.dbpprt.dieter.core.screens.InputReset
import com.dbpprt.dieter.core.screens.Modifiers
import com.dbpprt.dieter.core.screens.MouseButtons
import com.dbpprt.dieter.core.screens.Point
import com.dbpprt.dieter.core.screens.ScreenCanvas
import com.dbpprt.dieter.core.screens.ScreenKeyboard
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ScreenView
import com.dbpprt.dieter.core.screens.TouchTrackpad
import com.dbpprt.dieter.core.screens.TrackpadActions
import okio.ByteString
import org.webrtc.*
import java.util.concurrent.CountDownLatch
import kotlin.math.*
import kotlin.time.Instant

/**
 * A GPU-backed desktop canvas with a relative touchpad above it. The core
 * owns the session, input encoding, and cursor adoption; this view renders
 * frames, draws the cursor, and turns touches into trackpad gestures.
 */
class ScreenCanvasView(context: Context, val host: ScreenHost) : FrameLayout(context) {
    val canvasModel: ScreenCanvas = host.canvas
    private val media = host.media
    private val texture = TextureView(context)
    private val direct = media.directSurfacePresentation
    private val surface = if (media.surfacePresentation || direct) SurfaceView(context) else null
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
    private val resetListener: () -> Unit = { post(::clearFrame) }
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
    private val cursorShapes = LinkedHashMap<ByteString, Bitmap>()
    private var cursorBitmap: Bitmap? = null
    private var screen = ScreenView()
    private val touchConfiguration = ViewConfiguration.get(context)
    private var canvasAnimation: ValueAnimator? = null
    private var animationTargetZoom = 1.0
    private var geometryApplied = false
    var onCanvasChanged: (() -> Unit)? = null
    private var controlling = false
    private var holding = false
    var modifiers = 0
    private val gestures = TouchTrackpad(
        touchConfiguration.scaledTouchSlop.toDouble(), touchConfiguration.scaledDoubleTapSlop.toDouble(),
        ViewConfiguration.getDoubleTapTimeout().toLong(),
        object : TrackpadActions {
            override fun move(delta: Point) {
                canvasModel.move(delta.x, delta.y)
                host.pointer(canvasModel.cursor.x, canvasModel.cursor.y)
                applyCanvasTransform()
            }
            override fun transform(factor: Double, oldCenter: Point, newCenter: Point) {
                canvasModel.transform(factor, oldCenter, newCenter); applyCanvasTransform()
            }
            override fun button(down: Boolean, clicks: Int) = button(Button.BUTTON_LEFT, down, clicks)
            override fun scroll(delta: Point, phase: Int) {
                val density = resources.displayMetrics.density
                host.scroll(delta.x / density, delta.y / density, phase)
            }
            override fun clicked() = notifyClick()
        },
    )
    private val mouseButtons = MouseButtons(ViewConfiguration.getDoubleTapTimeout().toLong(),
        touchConfiguration.scaledTouchSlop.toFloat()) { mask, down, count ->
        val which = when (mask) {
            MotionEvent.BUTTON_SECONDARY -> Button.BUTTON_RIGHT
            MotionEvent.BUTTON_TERTIARY -> Button.BUTTON_MIDDLE
            MotionEvent.BUTTON_BACK -> Button.BUTTON_BACK
            MotionEvent.BUTTON_FORWARD -> Button.BUTTON_FORWARD
            else -> Button.BUTTON_LEFT
        }
        button(which, down, count)
    }
    private val longPress = Runnable {
        if (controlling && gestures.longPress()) {
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            syncHolding()
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
        renderer.init(media.egl.eglBaseContext, EglBase.CONFIG_PLAIN, GlRectDrawer())
        initialized = true
        renderer.addRenderListener { submittedAt ->
            val timestamp = drawnTimestamp; val w = drawnWidth; val h = drawnHeight
            media.presented(timestamp, drawnSession, (submittedAt - drawnArrival).coerceAtLeast(0) / 1_000_000.0)
            if (direct) {
                val session = drawnSession
                post { if (!released && media.acceptsFrame(session)) { texture.alpha = 1f; directCover.visibility = GONE } }
            }
            val session = drawnSession
            if (w != frameWidth || h != frameHeight) post {
                if (!released && media.acceptsFrame(session)) { frameWidth = w; frameHeight = h; geometry() }
            }
        }
        texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                if (!released) { renderer.createEglSurface(surface); geometry(); host.refresh() }
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
                            if (!released && decoderSurface === target && metadata != null && media.acceptsFrame(metadata.first)) {
                                texture.alpha = 0f; directCover.visibility = GONE
                                media.presented(timestamp, metadata.first,
                                    (renderedAt - decodedAt).coerceAtLeast(0) / 1_000_000.0,
                                    RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_ANDROID_FRAME_RENDERED)
                            }
                        }
                        decoderSurface = target
                        media.attachDecoderSurface(target)
                    } else renderer.createEglSurface(holder.surface)
                    geometry(); host.refresh()
                }
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = geometry()
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (direct) {
                    clearPendingDirect()
                    decoderSurface?.let(media::detachDecoderSurface)
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
        media.videoSink = sink
        media.onVideoReset = resetListener
    }
    private fun onFrame(frame: VideoFrame, token: Long) {
        if (released || !media.acceptsFrame(token)) return
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
            post { if (!released && media.acceptsFrame(token)) videoView.visibility = VISIBLE }
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
            if (released || !media.acceptsFrame(session)) return
            if (frame.rotation != 0) {
                // Surface layout handles canvas transforms, not per-frame
                // rotation. Closing the optional target forces texture fallback.
                decoderSurface?.close(); host.resume(); return
            }
            if (frameWidth != frame.rotatedWidth || frameHeight != frame.rotatedHeight) {
                frameWidth = frame.rotatedWidth; frameHeight = frame.rotatedHeight; geometry()
            }
            synchronized(frameSessions) {
                if (frameSessions.size >= 32) frameSessions.remove(frameSessions.keys.first())
                frameSessions[frame.timestampNs] = session to System.nanoTime()
            }
            val displayed = runCatching { (frame.buffer as VideoFrame.SurfaceBuffer).render() }.getOrElse {
                decoderSurface?.close(); host.resume(); false
            }
            if (!displayed) synchronized(frameSessions) { frameSessions.remove(frame.timestampNs) }
        } finally { frame.release() }
    }
    private fun clearPendingDirect() {
        synchronized(directLock) { pendingDirect?.first?.release(); pendingDirect = null }
    }
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) { super.onSizeChanged(w, h, oldw, oldh); geometry() }
    private fun geometry() {
        // Texture/surface callbacks can repeat during composition. A no-op size
        // update must not cancel the button animation half way through a step.
        if (geometryApplied && canvasModel.viewWidth == width.toDouble() && canvasModel.viewHeight == height.toDouble() &&
            canvasModel.remoteWidth == frameWidth.toDouble() && canvasModel.remoteHeight == frameHeight.toDouble()) return
        canvasAnimation?.cancel()
        canvasModel.resize(width.toDouble(), height.toDouble(), frameWidth.toDouble(), frameHeight.toDouble())
        geometryApplied = true
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
            setScale((m.remoteWidth * m.scale / width.coerceAtLeast(1)).toFloat(), (m.remoteHeight * m.scale / height.coerceAtLeast(1)).toFloat())
            postTranslate(m.left.toFloat(), m.top.toFloat())
        })
        if (direct) surface?.let {
            // Fixed decoder-sized storage; zoom only changes compositor geometry.
            // Allocating a zoom-sized buffer would multiply bandwidth and memory.
            // Keep layout/buffer allocation independent of gesture cadence.
            // RenderNode properties move the existing surface each display frame.
            if (it.layoutParams.width != frameWidth || it.layoutParams.height != frameHeight) {
                it.holder.setFixedSize(frameWidth, frameHeight)
                it.layoutParams = LayoutParams(frameWidth, frameHeight)
            }
            it.pivotX = 0f; it.pivotY = 0f
            it.scaleX = m.scale.toFloat(); it.scaleY = m.scale.toFloat()
            it.translationX = m.left.toFloat(); it.translationY = m.top.toFloat()
        }
        invalidate()
        onCanvasChanged?.invoke()
    }
    /** Fits and centers the desktop; the cursor stays where the host has it. */
    fun resetCanvas(animated: Boolean = false) = changeCanvas(animated) {
        val cursor = canvasModel.cursor
        canvasModel.reset(); canvasModel.setCursor(cursor.x, cursor.y)
    }
    fun zoomCanvas(factor: Double) {
        val base = if (canvasAnimation?.isRunning == true) animationTargetZoom else canvasModel.zoom
        val target = (base * factor).coerceIn(ScreenCanvas.MIN_ZOOM, ScreenCanvas.MAX_ZOOM)
        changeCanvas(true) {
            val center = Point(width / 2.0, height / 2.0)
            canvasModel.transform(target / canvasModel.zoom, center, center)
        }
    }
    private fun changeCanvas(animated: Boolean, change: () -> Unit) {
        canvasAnimation?.cancel()
        val m = canvasModel
        val startZoom = m.zoom; val startX = m.panX; val startY = m.panY
        change()
        if (!animated) { applyCanvasTransform(); return }
        val endZoom = m.zoom; val endX = m.panX; val endY = m.panY
        animationTargetZoom = endZoom
        m.setView(startZoom, startX, startY)
        canvasAnimation = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 180
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                val fraction = (it.animatedValue as Float).toDouble()
                m.setView(startZoom + (endZoom - startZoom) * fraction,
                    startX + (endX - startX) * fraction, startY + (endY - startY) * fraction)
                applyCanvasTransform()
            }
            start()
        }
    }
    /** Applies the session's latest view: input availability, display changes, and the host cursor. */
    fun update(view: ScreenView) {
        val previous = screen
        screen = view
        when (InputReset.between(previous, view)) {
            InputReset.ALL -> { cancelGesture(); mouseButtons.release(); modifiers = 0 }
            InputReset.GESTURE -> { cancelGesture(); mouseButtons.release() }
            InputReset.NONE -> Unit
        }
        controlling = view.controlActive
        isClickable = controlling
        // The core adopts the host position only when no local gesture holds the cursor.
        if (previous.cursorX != view.cursorX || previous.cursorY != view.cursorY) canvasModel.setCursor(view.cursorX, view.cursorY)
        if (previous.cursorImage != view.cursorImage) cursorBitmap = view.cursorImage?.let(::cursorImage)
        invalidate()
    }

    /** Forgets zoom, pan, and cursor for a new session. */
    fun resetSession() {
        canvasModel.reset()
        clearFrame()
    }
    fun clearFrame() {
        if (released) return
        cancelGesture(); mouseButtons.release(); canvasAnimation?.cancel()
        visibleSession = -1L
        if (direct) { directCover.visibility = VISIBLE; texture.alpha = 1f; clearPendingDirect() }
        else videoView.visibility = INVISIBLE
        synchronized(frameSessions) { frameSessions.clear() }
        paused = true; renderer.pauseVideo()
        renderer.clearImage(12 / 255f, 15 / 255f, 20 / 255f, 1f)
        cursorShapes.clear(); cursorBitmap = null
        // A reconnect can reset the model without changing decoded dimensions.
        // Reapply now so video, cursor, and hit testing share the same transform.
        applyCanvasTransform()
    }
    fun release() {
        if (released) return
        cancelGesture(); mouseButtons.release(); canvasAnimation?.cancel(); host.releaseInput()
        if (media.videoSink === sink) media.videoSink = null
        if (media.onVideoReset === resetListener) media.onVideoReset = null
        released = true; initialized = false
        clearPendingDirect()
        decoderSurface?.let(media::detachDecoderSurface); decoderSurface = null
        renderer.release(); cursorShapes.clear(); cursorBitmap = null
    }
    private fun cursorImage(png: ByteString): Bitmap? {
        cursorShapes[png]?.let { return it }
        if (png.size !in 1..262144) return null
        val raw = png.toByteArray()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
        if (bounds.outWidth !in 1..512 || bounds.outHeight !in 1..512) return null
        val bitmap = BitmapFactory.decodeByteArray(raw, 0, raw.size) ?: return null
        if (cursorShapes.size >= 32) cursorShapes.clear()
        cursorShapes[png] = bitmap
        return bitmap
    }
    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (screen.phase != ScreenPhase.Streaming) return
        val m = canvasModel
        val x = (m.left + m.cursor.x * m.remoteWidth * m.scale).toFloat()
        val y = (m.top + m.cursor.y * m.remoteHeight * m.scale).toFloat()
        val bitmap = cursorBitmap
        // Keep the pointer legible on a phone, independent of desktop resolution.
        val size = max(resources.displayMetrics.density, m.scale.toFloat())
        if (bitmap != null && screen.cursorVisible) {
            val left = x - screen.cursorHotspotX.toFloat() * size; val top = y - screen.cursorHotspotY.toFloat() * size
            canvas.drawBitmap(bitmap, null, RectF(left, top, left + screen.cursorWidth.toFloat() * size, top + screen.cursorHeight.toFloat() * size), paint)
        } else {
            val path = Path().apply { moveTo(x, y); lineTo(x + 5 * size, y + 18 * size); lineTo(x + 9 * size, y + 12 * size); lineTo(x + 16 * size, y + 10 * size); close() }
            paint.style = Paint.Style.FILL; paint.color = Color.WHITE; canvas.drawPath(path, paint)
            paint.style = Paint.Style.STROKE; paint.strokeWidth = size; paint.color = Color.BLACK; canvas.drawPath(path, paint); paint.style = Paint.Style.FILL
        }
    }
    private fun button(which: Button, down: Boolean, count: Int = 1) = host.button(which, down, count, canvasModel.cursor.x, canvasModel.cursor.y, modifiers)
    private fun notifyClick() { super.performClick() }
    fun click(which: Button = Button.BUTTON_LEFT) {
        if (!controlling) return
        requestFocus()
        button(which, true); button(which, false); notifyClick()
    }
    override fun performClick(): Boolean {
        if (!controlling) return false
        click(); return true
    }
    private fun cancelGesture() { removeCallbacks(longPress); gestures.cancel(); syncHolding() }
    /** Tells the core while a finger or mouse drag holds the cursor, so host updates do not fight it. */
    private fun syncHolding() {
        val value = gestures.holdingCursor || mouseButtons.isDragging
        if (value != holding) { holding = value; host.holdCursor(value) }
    }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) return mouse(event)
        fun point(index: Int) = Point(event.getX(index).toDouble(), event.getY(index).toDouble())
        fun fingers(except: Int = -1) = (0 until event.pointerCount).filter { it != except }.associate { event.getPointerId(it) to point(it) }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                canvasAnimation?.cancel(); requestFocus()
                parent?.requestDisallowInterceptTouchEvent(true)
                gestures.begin(event.getPointerId(0), point(0), controlling)
                postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
            }
            MotionEvent.ACTION_POINTER_DOWN -> { removeCallbacks(longPress); gestures.fingers(fingers()) }
            MotionEvent.ACTION_POINTER_UP -> { removeCallbacks(longPress); gestures.fingers(fingers(except = event.actionIndex)) }
            MotionEvent.ACTION_MOVE -> {
                gestures.move(fingers())
                if (!gestures.canLongPress) removeCallbacks(longPress)
            }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPress)
                gestures.end(event.getPointerId(0), point(0), Instant.fromEpochMilliseconds(event.eventTime))
                parent?.requestDisallowInterceptTouchEvent(false)
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelGesture(); host.releaseInput()
                parent?.requestDisallowInterceptTouchEvent(false)
            }
        }
        syncHolding()
        return true
    }
    private fun mouse(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_CANCEL) {
            mouseButtons.release(); syncHolding(); host.releaseInput(); return true
        }
        val m = canvasModel
        val inside = m.contains(event.x.toDouble(), event.y.toDouble())
        if (controlling && (inside || mouseButtons.isDragging)) {
            m.setCursor((event.x - m.left) / (m.remoteWidth * m.scale), (event.y - m.top) / (m.remoteHeight * m.scale))
            host.pointer(m.cursor.x, m.cursor.y)
            invalidate()
        }
        val buttons = when (event.actionMasked) {
            MotionEvent.ACTION_UP -> 0
            MotionEvent.ACTION_BUTTON_RELEASE -> event.buttonState and event.actionButton.inv()
            MotionEvent.ACTION_BUTTON_PRESS -> event.buttonState or event.actionButton
            else -> event.buttonState
        }
        if (buttons != 0 && inside) requestFocus()
        mouseButtons.update(buttons, inside && controlling,
            newGesture = event.actionMasked == MotionEvent.ACTION_DOWN, time = event.eventTime, x = event.x, y = event.y)
        syncHolding()
        if (inside && event.actionMasked == MotionEvent.ACTION_SCROLL)
            host.scroll(event.getAxisValue(MotionEvent.AXIS_HSCROLL) * 40.0, event.getAxisValue(MotionEvent.AXIS_VSCROLL) * 40.0, 0)
        return true
    }
    override fun onGenericMotionEvent(event: MotionEvent): Boolean =
        if (event.source and InputDevice.SOURCE_MOUSE == InputDevice.SOURCE_MOUSE) mouse(event) else super.onGenericMotionEvent(event)
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (!hasWindowFocus) { cancelGesture(); mouseButtons.release(); editorBuffer.clear(); modifiers = 0 }
        host.focus(hasWindowFocus)
    }
    fun showKeyboard(show: Boolean) {
        requestFocus()
        val ime = context.getSystemService(InputMethodManager::class.java)
        if (show) ime.showSoftInput(this, 0)
        else { ime.hideSoftInputFromWindow(windowToken, 0); editorBuffer.clear(); host.releaseInput() }
    }
    override fun onCheckIsTextEditor() = true
    override fun onCreateInputConnection(info: EditorInfo): InputConnection {
        info.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        info.imeOptions = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_ENTER_ACTION or
            EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        return ScreenInputConnection(this, editorBuffer, { modifiers }, host::text, ::pressKey) { id ->
            when (id) {
                android.R.id.paste -> { host.paste(); true }
                android.R.id.cut -> { host.cut(); true }
                android.R.id.copy -> { host.copy(); true }
                else -> false
            }
        }
    }
    fun pressKey(hid: Int) { host.key(hid, true, modifiers); host.key(hid, false, modifiers) }
    override fun onKeyDown(code: Int, event: KeyEvent): Boolean {
        val hid = AndroidKeys.hid(code)
        if (hid != null) { host.key(hid, true, modifiers or event.remoteModifiers, event.repeatCount > 0); return true }
        if (event.unicodeChar > 0) { host.text(String(Character.toChars(event.unicodeChar))); return true }
        return super.onKeyDown(code, event)
    }
    override fun onKeyUp(code: Int, event: KeyEvent): Boolean {
        val hid = AndroidKeys.hid(code) ?: return super.onKeyUp(code, event)
        host.key(hid, false, modifiers or event.remoteModifiers); return true
    }
}

/** The modifier keys this event holds, as the remote protocol's mask. */
private val KeyEvent.remoteModifiers: Int get() = Modifiers.of(isShiftPressed, isCtrlPressed, isAltPressed, isMetaPressed)
