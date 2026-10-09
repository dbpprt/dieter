package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.ScreenCommand
import com.dbpprt.dieter.core.screens.DisplayMatching
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ScreenSurface

/**
 * Input is frequent and its effect arrives with the next update, so screen commands have no result.
 * [routes] resolves a machine's signaling route.
 */
internal suspend fun ScreenSurface.execute(
    command: ScreenCommand,
    routes: (daemonId: String) -> ScreenRouteFactory,
) {
    command.control?.let { session.transferControl(it.on) }
    command.clipboard?.let { session.requestClipboard(it.operation) }
    command.clipboard_enabled?.let { session.requestClipboardEnabled(it.on) }
    command.connect?.let { session.connect(it.daemon_id, routes(it.daemon_id)) }
    command.disconnect?.let { session.disconnect() }
    command.viewport?.let { session.viewport(it.width_points, it.height_points, it.scale) }
    command.preferences?.let { wanted ->
        session.setPreferences {
            it.copy(
                codec = wanted.codec,
                maxFps = wanted.max_fps.takeIf { fps -> fps > 0 } ?: it.maxFps,
                quality = wanted.quality,
                displayId = wanted.display_id.ifEmpty { null },
                clipboard = wanted.clipboard,
                virtualDisplay = wanted.virtual_display,
                disablePhysical = wanted.disable_physical,
                virtualScale = wanted.virtual_scale.takeIf { scale -> scale in 1..2 } ?: 2,
            )
        }
    }
    session.applyInput(command)
    command.resume?.let { session.resume() }
    command.sleep?.let { session.sleep() }
    command.focused?.let { session.setFocused(it.on) }
    command.match_display?.let {
        matchDisplay(
            if (it.width > 0 && it.height > 0)
                DisplayMatching.Target(it.width, it.height, it.scale, it.refresh)
            else null
        )
    }
    command.refresh?.let { session.configure(refresh = true) }
}
