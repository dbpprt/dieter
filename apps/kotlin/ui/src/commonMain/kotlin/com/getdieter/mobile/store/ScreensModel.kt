package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/** A machine's shared screen: its session slice, the machine shown, and canvas controls. */
class ScreensModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(ScreenSlice())
    val selected = MutableStateFlow("")
    internal val canvasActions = MutableSharedFlow<String>(extraBufferCapacity = 8)

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_SCREEN, MobileStore.SCREEN_SCOPE) {
            it.screen?.let { value ->
                slice.value =
                    if (value.cursor_image_unchanged)
                        value.copy(cursor_image = slice.value.cursor_image)
                    else value
            }
        }
    }

    internal fun open(machineId: String) {
        selected.value = machineId
    }

    internal fun close() {
        context.command(
            Command(screen = ScreenCommand(scope = MobileStore.SCREEN_SCOPE, disconnect = Step()))
        )
        selected.value = ""
    }

    /** Sends pointer, key and clipboard input in order with terminal input. */
    fun input(command: ScreenCommand) =
        context.input(Command(screen = command.copy(scope = MobileStore.SCREEN_SCOPE)))

    internal suspend fun foreground(active: Boolean) {
        if (selected.value.isNotEmpty())
            context.core.dispatch(
                Command(
                    screen =
                        ScreenCommand(
                            scope = MobileStore.SCREEN_SCOPE,
                            resume = if (active) Step() else null,
                            sleep = if (!active) Step() else null,
                        )
                )
            )
    }
}
