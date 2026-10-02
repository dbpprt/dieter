package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.core.screens.DisplayMatching
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ScreenSurface

/**
 * Input is frequent and its effect arrives with the next update, so screen
 * commands have no result. [routes] resolves a machine's signaling route.
 */
internal suspend fun ScreenSurface.execute(command: ScreenCommand, routes: (daemonId: String) -> ScreenRouteFactory) {
    command.control?.let { session.transferControl(it.on) }
    command.clipboard?.let { session.performClipboard(it.operation) }
    command.clipboard_enabled?.let { session.setClipboardEnabled(it.on) }
    command.connect?.let { session.connect(routes(it.daemon_id)) }
    command.disconnect?.let { session.disconnect() }
    command.viewport?.let { session.viewport(it.width_points, it.height_points, it.scale) }
    command.preferences?.let { wanted ->
        session.setPreferences {
            it.copy(
                codec = wanted.codec, maxFps = wanted.max_fps.takeIf { fps -> fps > 0 } ?: it.maxFps, quality = wanted.quality,
                displayId = wanted.display_id.ifEmpty { null }, clipboard = wanted.clipboard,
            )
        }
    }
    command.pointer?.let { session.pointer(it.x, it.y) }
    command.button?.let { session.button(it.button, it.down, it.clicks, it.x, it.y, it.modifiers) }
    command.scroll?.let { session.scroll(it.dx, it.dy, it.phase, it.momentum, it.modifiers, it.precise) }
    command.key?.let { session.key(it.hid, it.down, it.repeat, it.modifiers) }
    command.text?.let { session.text(it.text, it.modifiers) }
    command.release_input?.let { session.releaseInput() }
    command.resume?.let { session.resume() }
    command.sleep?.let { session.sleep() }
    command.focused?.let { session.setFocused(it.on) }
    command.match_display?.let {
        matchDisplay(if (it.width > 0 && it.height > 0) DisplayMatching.Target(it.width, it.height, it.scale, it.refresh) else null)
    }
    command.refresh?.let { session.configure(refresh = true) }
}
