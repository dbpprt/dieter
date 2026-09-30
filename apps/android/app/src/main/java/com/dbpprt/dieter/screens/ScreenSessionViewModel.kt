package com.dbpprt.dieter.screens

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.screens.ScreenCanvas
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ScreenSession
import com.dbpprt.dieter.core.screens.ScreenView
import com.dbpprt.dieter.core.screens.ViewportPolicy
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** Retains the peer and canvas through Activity rotation, but never across leaving Screens. */
class ScreenSessionViewModel(application: Application) : AndroidViewModel(application) {
    private var host: ScreenHost? = null

    fun host(): ScreenHost = host ?: ScreenHost(getApplication(), (getApplication<Application>() as DieterApplication).container.core).also { host = it }

    fun leave() {
        host?.close()
        host = null
    }

    override fun onCleared() = leave()
}

/**
 * The Screens view's handle on one core [ScreenSession]. Every call is made
 * on the main thread and hops, in order, onto the core dispatcher that owns
 * the session. The canvas geometry is view state and stays on the main thread.
 */
class ScreenHost internal constructor(
    context: Context,
    private val core: CoreRuntime,
    val media: AndroidScreenMedia = AndroidScreenMedia(context),
    /** How a machine's screen is reached; tests substitute an isolated native fixture. */
    private val routes: (String) -> ScreenRouteFactory = core::screenRoutes,
) : AutoCloseable {
    // Construction has no side effects; everything after it runs on the core dispatcher.
    private val session: ScreenSession = core.screen(media, ScreenConfig("Android", ViewportPolicy.Fixed), AndroidClipboard(context))
    val view: StateFlow<ScreenView> = session.view
    val stats: StateFlow<ScreenMediaStats> = media.stats
    val canvas = ScreenCanvas()
    private var closed = false

    init {
        media.onDecoderSurfaceReplaced = { resume() }
    }

    private fun onCore(block: suspend ScreenSession.() -> Unit) {
        if (closed) return
        core.scope.launch { session.block() }
    }

    fun connect(daemonId: String) = onCore { connect(routes(daemonId)) }
    fun disconnect() = onCore { disconnect() }
    fun resume() = onCore { resume() }
    fun focus(focused: Boolean) = onCore { setFocused(focused) }
    fun refresh() = onCore { configure(refresh = true) }
    fun selectDisplay(id: String) = onCore { setPreferences { it.copy(displayId = id) } }
    fun selectQuality(quality: RemoteDesktopQuality) = onCore { setQuality(quality) }
    fun selectCodec(codec: RemoteDesktopCodecPreference) = onCore { setPreferences { it.copy(codec = codec) } }
    fun selectMaxFps(fps: Int) = onCore { setPreferences { it.copy(maxFps = fps) } }
    fun holdCursor(holding: Boolean) = onCore { holdingCursor = holding }

    fun pointer(x: Double, y: Double) = onCore { pointer(x, y) }
    fun button(button: RemoteDesktopPointerButton.Button, down: Boolean, clicks: Int, x: Double, y: Double, modifiers: Int) =
        onCore { button(button, down, clicks, x, y, modifiers) }
    fun scroll(dx: Double, dy: Double, phase: Int) = onCore { scroll(dx, dy, phase) }
    fun key(hid: Int, down: Boolean, modifiers: Int = 0, repeat: Boolean = false) = onCore { key(hid, down, repeat, modifiers) }
    fun text(value: String, modifiers: Int = 0) = onCore { text(value, modifiers) }
    fun releaseInput() = onCore { releaseInput() }

    fun copy() = onCore { performClipboard("copy") }
    fun cut() = onCore { performClipboard("cut") }
    fun paste() = onCore { performClipboard("paste") }
    fun setClipboardEnabled(enabled: Boolean) = onCore { setClipboardEnabled(enabled) }

    fun transferControl(take: Boolean) = onCore { transferControl(take) }

    override fun close() {
        if (closed) return
        onCore {
            disconnect()
            media.close()
        }
        closed = true
    }
}
