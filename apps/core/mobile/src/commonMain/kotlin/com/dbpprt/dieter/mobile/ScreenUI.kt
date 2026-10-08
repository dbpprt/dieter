package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.client.v1.*

/** Remote screen: native video and input fill the screen; controls float above them. */
@Composable
internal fun NativeScreen(store: MobileStore, machineId: String) {
    val view by store.screen.collectAsState()
    val session by store.session.collectAsState()
    var keyboard by remember { mutableStateOf(false) }
    val machine = session.machines.firstOrNull { it.id == machineId }
    fun send(value: ScreenCommand) =
        store.command(Command(screen = value.copy(scope = MobileStore.SCREEN_SCOPE)))
    fun preferences() = view.preferences ?: ScreenPreferences()
    fun quality(value: RemoteDesktopQuality) =
        value.name
            .removePrefix("REMOTE_DESKTOP_QUALITY_")
            .lowercase()
            .replaceFirstChar(Char::uppercase)
    val menu =
        listOf(
            MenuSection(
                listOf(
                    ChromeAction(
                        "control",
                        view.control_label.ifEmpty {
                            if (view.control_active) "Release control" else "Take control"
                        },
                        Glyph.MOUSE,
                        checked = view.control_active,
                        enabled = view.can_transfer_control && !view.control_transferring,
                    ) {
                        send(ScreenCommand(control = Toggle(!view.control_active)))
                    },
                    ChromeAction(
                        "paste",
                        "Paste to machine",
                        Glyph.PASTE,
                        enabled = view.clipboard_actions_enabled,
                    ) {
                        send(ScreenCommand(clipboard = ScreenClipboardOperation("paste")))
                    },
                    ChromeAction(
                        "share-clipboard",
                        "Share clipboard",
                        Glyph.COPY,
                        checked = view.clipboard_enabled,
                    ) {
                        send(ScreenCommand(clipboard_enabled = Toggle(!view.clipboard_enabled)))
                    },
                )
            ),
            MenuSection(
                listOf(
                    ChromeAction(
                        "quality",
                        "Quality",
                        Glyph.WAND,
                        menu =
                            listOf(
                                MenuSection(
                                    RemoteDesktopQuality.entries
                                        .filter { it.value > 0 }
                                        .map { option ->
                                            ChromeAction(
                                                "quality-${option.name}",
                                                quality(option),
                                                checked = preferences().quality == option,
                                            ) {
                                                send(
                                                    ScreenCommand(
                                                        preferences =
                                                            preferences().copy(quality = option)
                                                    )
                                                )
                                            }
                                        }
                                )
                            ),
                    ),
                    ChromeAction(
                        "fps",
                        "Frame rate",
                        Glyph.BOLT,
                        menu =
                            listOf(
                                MenuSection(
                                    view.frame_rates.map { rate ->
                                        ChromeAction(
                                            "fps-$rate",
                                            "$rate fps",
                                            checked = preferences().max_fps == rate,
                                        ) {
                                            send(
                                                ScreenCommand(
                                                    preferences = preferences().copy(max_fps = rate)
                                                )
                                            )
                                        }
                                    }
                                )
                            ),
                    ),
                    ChromeAction(
                        "codec",
                        "Codec",
                        Glyph.CPU,
                        menu =
                            listOf(
                                MenuSection(
                                    RemoteDesktopCodecPreference.entries
                                        .filter { it.value > 0 }
                                        .map { option ->
                                            ChromeAction(
                                                "codec-${option.name}",
                                                option.name.removePrefix(
                                                    "REMOTE_DESKTOP_CODEC_PREFERENCE_"
                                                ),
                                                checked = preferences().codec == option,
                                            ) {
                                                send(
                                                    ScreenCommand(
                                                        preferences =
                                                            preferences().copy(codec = option)
                                                    )
                                                )
                                            }
                                        }
                                )
                            ),
                    ),
                    ChromeAction(
                        "display",
                        "Display",
                        Glyph.SCREENS,
                        enabled = (view.capabilities?.displays?.size ?: 0) > 1,
                        menu =
                            listOf(
                                MenuSection(
                                    view.capabilities?.displays.orEmpty().map { display ->
                                        ChromeAction(
                                            "display-${display.id}",
                                            display.name.ifEmpty { "Display ${display.id}" },
                                            checked = preferences().display_id == display.id,
                                        ) {
                                            send(
                                                ScreenCommand(
                                                    preferences =
                                                        preferences().copy(display_id = display.id)
                                                )
                                            )
                                            store.canvasActions.tryEmit("fit")
                                        }
                                    }
                                )
                            ),
                    ),
                )
            ),
            MenuSection(
                listOf(
                    ChromeAction("refresh-frame", "Refresh frame", Glyph.REFRESH) {
                        send(ScreenCommand(refresh = Step()))
                    }
                )
            ),
        )
    Screen(
        ScreenChrome(
            machine?.display_name ?: "Screen",
            subtitle = view.status_line.ifEmpty { view.phase_label },
            actions =
                listOf(
                    ChromeAction(
                        "screen-menu",
                        "Screen options",
                        Glyph.MORE_HORIZONTAL,
                        menu = menu,
                    )
                ),
        )
    ) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            Column(Modifier.fillMaxSize().padding(top = padding.calculateTopPadding())) {
                if (view.problem.isNotEmpty())
                    Banner(
                        view.phase_label,
                        view.problem,
                        Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Resume",
                        onAction = { send(ScreenCommand(resume = Step())) },
                    )
                listOf(view.control_error, view.clipboard_error)
                    .filter { it.isNotEmpty() }
                    .forEach {
                        Banner(
                            "Screen",
                            it,
                            Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                            tone = Tone.DANGER,
                        )
                    }
                NativeScreenCanvas(
                    store,
                    Modifier.weight(1f).fillMaxWidth().testTag("screen-canvas"),
                )
            }
            Row(
                Modifier.align(Alignment.BottomCenter)
                    .padding(bottom = padding.calculateBottomPadding() + 8.dp)
                    .clip(CircleShape)
                    .background(Color(0xCC1C1C1E))
                    .padding(horizontal = 6.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenTool(Glyph.ZOOM_OUT, "Zoom out") { store.canvasActions.tryEmit("zoom-out") }
                ScreenTool(Glyph.FIT, "Fit screen") { store.canvasActions.tryEmit("fit") }
                ScreenTool(Glyph.ZOOM_IN, "Zoom in") { store.canvasActions.tryEmit("zoom-in") }
                Box(Modifier.width(1.dp).height(22.dp).background(Color(0x55FFFFFF)))
                ScreenTool(
                    Glyph.KEYBOARD,
                    if (keyboard) "Hide keyboard" else "Show keyboard",
                    enabled = view.control_active,
                    active = keyboard,
                ) {
                    keyboard = !keyboard
                    store.canvasActions.tryEmit(if (keyboard) "keyboard-show" else "keyboard-hide")
                }
                ScreenTool(Glyph.MOUSE, "Right click", enabled = view.control_active) {
                    listOf(true, false).forEach { pressed ->
                        store.inputCommand(
                            Command(
                                screen =
                                    ScreenCommand(
                                        scope = MobileStore.SCREEN_SCOPE,
                                        button =
                                            ScreenButton(
                                                RemoteDesktopPointerButton.Button.BUTTON_RIGHT,
                                                pressed,
                                                1,
                                                view.cursor_x,
                                                view.cursor_y,
                                            ),
                                    )
                            )
                        )
                    }
                }
            }
            val details = listOf(view.latency_label, view.viewers_label).filter { it.isNotEmpty() }
            if (details.isNotEmpty())
                Text(
                    details.joinToString(" · "),
                    Modifier.align(Alignment.TopEnd)
                        .padding(top = padding.calculateTopPadding() + 8.dp, end = 12.dp)
                        .clip(CircleShape)
                        .background(Color(0x99000000))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                    style = type.caption,
                    color = Color.White,
                )
        }
    }
    // The native renderer attaches before the connection creates its media engine.
    LaunchedEffect(machineId) { send(ScreenCommand(connect = ScreenConnect(machineId))) }
}

@Composable
private fun ScreenTool(
    glyph: Glyph,
    description: String,
    enabled: Boolean = true,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(44.dp)
            .clip(CircleShape)
            .background(if (active) Color(0x33FFFFFF) else Color.Transparent)
            .pressable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            glyph,
            description,
            tint = if (enabled) Color.White else Color(0x66FFFFFF),
            size = 20.dp,
        )
    }
}
