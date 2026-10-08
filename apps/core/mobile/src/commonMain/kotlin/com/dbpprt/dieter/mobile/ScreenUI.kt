package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.client.v1.*

@Composable
internal fun NativeScreen(store: MobileStore, modifier: Modifier) {
    val view by store.screen.collectAsState()
    val machine by store.selectedScreen.collectAsState()
    var keyboard by remember { mutableStateOf(false) }
    fun send(value: ScreenCommand) =
        store.command(Command(screen = value.copy(scope = MobileStore.SCREEN_SCOPE)))
    Column(modifier) {
        PageHeader("Remote screen", view.status_line, back = store::closeScreen)
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                view.control_active,
                { send(ScreenCommand(control = Toggle(!view.control_active))) },
                label = { Text(view.control_label.ifEmpty { "Take control" }) },
                enabled = view.can_transfer_control && !view.control_transferring,
            )
            ChoiceChip(
                "${view.preferences?.max_fps ?: 60} fps",
                view.frame_rates.map { it.toString() to "$it fps" },
            ) {
                send(
                    ScreenCommand(
                        preferences =
                            (view.preferences ?: ScreenPreferences()).copy(max_fps = it.toInt())
                    )
                )
            }
            ChoiceChip(
                "Quality",
                RemoteDesktopQuality.entries
                    .filter { it.value > 0 }
                    .map {
                        it.name to
                            it.name
                                .removePrefix("REMOTE_DESKTOP_QUALITY_")
                                .lowercase()
                                .replaceFirstChar(Char::uppercase)
                    },
            ) {
                send(
                    ScreenCommand(
                        preferences =
                            (view.preferences ?: ScreenPreferences()).copy(
                                quality = RemoteDesktopQuality.valueOf(it)
                            )
                    )
                )
            }
            ChoiceChip(
                "Codec",
                RemoteDesktopCodecPreference.entries
                    .filter { it.value > 0 }
                    .map { it.name to it.name.removePrefix("REMOTE_DESKTOP_CODEC_PREFERENCE_") },
            ) {
                send(
                    ScreenCommand(
                        preferences =
                            (view.preferences ?: ScreenPreferences()).copy(
                                codec = RemoteDesktopCodecPreference.valueOf(it)
                            )
                    )
                )
            }
            ChoiceChip(
                "Display",
                view.capabilities?.displays.orEmpty().map {
                    it.id to it.name.ifEmpty { "Display ${it.id}" }
                },
            ) {
                send(
                    ScreenCommand(
                        preferences =
                            (view.preferences ?: ScreenPreferences()).copy(display_id = it)
                    )
                )
                store.canvasActions.tryEmit("fit")
            }
            AssistChip(
                onClick = { send(ScreenCommand(clipboard = ScreenClipboardOperation("paste"))) },
                label = { Text("Paste") },
                enabled = view.clipboard_actions_enabled,
            )
            FilterChip(
                view.clipboard_enabled,
                { send(ScreenCommand(clipboard_enabled = Toggle(!view.clipboard_enabled))) },
                label = { Text("Share clipboard") },
            )
        }
        if (view.problem.isNotEmpty())
            Notice(view.phase_label, view.problem, { send(ScreenCommand(resume = Step())) })
        if (view.control_error.isNotEmpty()) Text(view.control_error, color = colors.error)
        if (view.clipboard_error.isNotEmpty()) Text(view.clipboard_error, color = colors.error)
        NativeScreenCanvas(store, Modifier.weight(1f).fillMaxWidth())
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp)) {
            TextButton(onClick = { store.canvasActions.tryEmit("zoom-out") }) { Text("−") }
            TextButton(onClick = { store.canvasActions.tryEmit("fit") }) { Text("Fit screen") }
            TextButton(onClick = { store.canvasActions.tryEmit("zoom-in") }) { Text("+") }
            TextButton(
                onClick = {
                    keyboard = !keyboard
                    store.canvasActions.tryEmit(if (keyboard) "keyboard-show" else "keyboard-hide")
                },
                enabled = view.control_active,
            ) {
                Text(if (keyboard) "Hide keyboard" else "Show keyboard")
            }
            TextButton(
                onClick = {
                    store.inputCommand(
                        Command(
                            screen =
                                ScreenCommand(
                                    scope = MobileStore.SCREEN_SCOPE,
                                    button =
                                        ScreenButton(
                                            com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
                                                .Button
                                                .BUTTON_RIGHT,
                                            true,
                                            1,
                                            view.cursor_x,
                                            view.cursor_y,
                                        ),
                                )
                        )
                    )
                    store.inputCommand(
                        Command(
                            screen =
                                ScreenCommand(
                                    scope = MobileStore.SCREEN_SCOPE,
                                    button =
                                        ScreenButton(
                                            com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
                                                .Button
                                                .BUTTON_RIGHT,
                                            false,
                                            1,
                                            view.cursor_x,
                                            view.cursor_y,
                                        ),
                                )
                        )
                    )
                },
                enabled = view.control_active,
            ) {
                Text("Right click")
            }
            TextButton(onClick = { send(ScreenCommand(refresh = Step())) }) {
                Text("Refresh frame")
            }
        }
        Text(
            listOf(view.metadata, view.latency_label, view.viewers_label)
                .filter { it.isNotEmpty() }
                .joinToString(" · "),
            Modifier.padding(12.dp),
            style = MaterialTheme.typography.labelSmall,
        )
    }
    // The native renderer attaches before the connection creates its media engine.
    LaunchedEffect(machine) { send(ScreenCommand(connect = ScreenConnect(machine))) }
    DisposableEffect(store) { onDispose { send(ScreenCommand(disconnect = Step())) } }
}
