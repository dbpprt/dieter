package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.viewmodel.compose.viewModel
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import com.dbpprt.dieter.screens.ScreenSessionViewModel
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.dieter.screens.ScreenCanvasView
import com.dbpprt.dieter.screens.ScreenController
import com.dbpprt.dieter.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.v1.RemoteDesktopQuality
import kotlin.math.roundToInt

@Composable
fun ScreensScreen(state: DieterUiState, model: DieterViewModel, padding: PaddingValues) {
    val holder: ScreenSessionViewModel = viewModel()
    val controller = remember(holder) { holder.controller() }
    ScreenWorkspace(state.endpointConnections.filter { it.daemonId != null }, padding, controller,
        onLeave = holder::leave, openConnection = model::openScreenConnection)
}

@Composable
internal fun ScreenWorkspace(
    machines: List<com.dbpprt.dieter.connection.EndpointConnection>,
    padding: PaddingValues,
    controller: ScreenController,
    onLeave: () -> Unit = controller::close,
    openConnection: suspend (String) -> com.dbpprt.dieter.screens.ScreenConnection,
) {
    val screen by controller.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current
    val activity = LocalContext.current.screenActivity()
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var canvas by remember { mutableStateOf<ScreenCanvasView?>(null) }
    var machineMenu by remember { mutableStateOf(false) }
    var displayMenu by remember { mutableStateOf(false) }
    var qualityMenu by remember { mutableStateOf(false) }
    var help by remember { mutableStateOf(false) }
    var keyboard by remember { mutableStateOf(false) }
    var specialKeys by rememberSaveable { mutableStateOf(false) }
    var modifiers by remember { mutableIntStateOf(0) }
    val machine = machines.firstOrNull { it.id == selected }
    val active = screen.phase != "idle" && screen.phase != "failed"
    fun disconnect() { canvas?.showKeyboard(false); keyboard = false; modifiers = 0; controller.disconnect() }
    DisposableEffect(controller, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) {
                controller.focus(false)
            }
            if (event == Lifecycle.Event.ON_RESUME) controller.resumeConnection()
        }
        lifecycle.lifecycle.addObserver(observer)
        onDispose {
            lifecycle.lifecycle.removeObserver(observer)
            canvas?.release()
            if (activity?.isChangingConfigurations != true) onLeave()
        }
    }
    BackHandler(active || keyboard) { if (keyboard) { canvas?.showKeyboard(false); keyboard = false } else disconnect() }
    LaunchedEffect(screen.phase) {
        if (screen.phase == "idle" || screen.phase == "failed" || screen.phase == "reconnecting") canvas?.clearFrame()
    }
    LaunchedEffect(screen.control) { if (!screen.control) { modifiers = 0; canvas?.modifiers = 0 } }
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background,
        contentColor = MaterialTheme.colorScheme.onBackground) {
    Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box {
                TextButton(onClick = { machineMenu = true }, modifier = Modifier.testTag("screen-machine")) {
                    Text(machine?.label ?: "Select machine")
                }
                DropdownMenu(expanded = machineMenu, onDismissRequest = { machineMenu = false }) {
                    machines.forEach { endpoint -> DropdownMenuItem(
                        modifier = Modifier.testTag("screen-machine-${endpoint.id}"),
                        text = { Text(endpoint.label + when {
                            !endpoint.online -> " · Offline"
                            !endpoint.remoteDesktopReady -> " · Unavailable"
                            else -> ""
                        }) }, enabled = endpoint.online && endpoint.remoteDesktopReady,
                        onClick = { disconnect(); selected = endpoint.id; machineMenu = false },
                    ) }
                }
            }
            if (active) TextButton(onClick = ::disconnect, modifier = Modifier.testTag("screen-disconnect")) { Text("Disconnect") }
            else TextButton(enabled = machine?.online == true && machine.remoteDesktopReady, onClick = {
                controller.connect { openConnection(requireNotNull(selected)) }
            }, modifier = Modifier.testTag("screen-connect")) { Text(if (screen.phase == "failed") "Retry" else "Connect") }
            if (active) {
                Box {
                    IconButton(onClick = { displayMenu = true }) { Icon(Icons.Outlined.DesktopWindows, "Choose display") }
                    DropdownMenu(displayMenu, { displayMenu = false }) {
                        screen.capabilities.displaysList.forEach { display -> DropdownMenuItem(
                            text = { Text(display.name.ifBlank { "Display ${display.id}" }) },
                            onClick = { controller.configure(display = display.id); canvas?.resetCanvas(); displayMenu = false },
                        ) }
                    }
                }
            }
            Box {
                    IconButton(onClick = { qualityMenu = true }) { Icon(Icons.Outlined.Tune, "Screen quality") }
                    DropdownMenu(qualityMenu, { qualityMenu = false }) {
                        listOf("Auto" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_AUTO,
                            "Detail" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL,
                            "Responsive motion" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION).forEach { (label, value) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { controller.configure(quality = value); qualityMenu = false })
                        }
                        HorizontalDivider()
                        listOf("Automatic codec" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO,
                            "H.264 compatibility" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
                            "HEVC · up to 1080p60" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC).forEach { (label, value) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { controller.selectCodec(value); qualityMenu = false })
                        }
                        HorizontalDivider()
                        listOf(30, 60, 90, 120).filter { it <= (screen.capabilities.maxFps.takeIf { fps -> fps > 0 } ?: 60) }.forEach { fps ->
                            DropdownMenuItem(text = { Text("Up to $fps fps") }, onClick = { controller.configure(maxFPS = fps); qualityMenu = false })
                        }
                    }
            }
            IconButton(onClick = { help = true }) { Icon(Icons.Outlined.HelpOutline, "Screen gestures") }
        }
        if (screen.session.codec.isNotBlank()) Text(screen.session.codec + if (screen.codecFallbackReason.isNotBlank()) " · ${screen.codecFallbackReason}" else "",
            style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 12.dp))
        if (screen.error.isNotBlank()) Text(screen.error, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp))
        if (!active && machine?.online == true && !machine.remoteDesktopReady) Text(
            machine.remoteDesktopReason.ifBlank { "This machine cannot host a screen session." },
            color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp),
        )
        if (machines.isEmpty()) Text("Connect an enrolled machine to view its screen.", modifier = Modifier.padding(16.dp))
        if (!active && screen.error.isBlank()) Text("Use this screen as a trackpad. Move the remote cursor with one finger; zoom and pan with two.",
            style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp))
        if (screen.canTransferControl) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                TextButton(enabled = !screen.controlTransferPending, onClick = { controller.transferControl(!screen.session.controlActive) },
                    modifier = Modifier.testTag("screens.control")) {
                    Text(if (screen.session.controlActive) "Release Control" else "Take Control")
                }
                Text("${screen.session.connectedClients} viewers" + if (!screen.session.controlActive && screen.session.controllerName.isNotBlank())
                    " · ${screen.session.controllerName} controls" else "", style = MaterialTheme.typography.labelSmall)
            }
        }
        if (screen.controlError.isNotBlank()) Text(screen.controlError, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelSmall)
        AndroidView(factory = { ScreenCanvasView(it, controller).also { view -> canvas = view } },
            onRelease = { it.release(); if (canvas === it) canvas = null },
            modifier = Modifier.weight(1f).fillMaxWidth().testTag("screen-canvas"))
        if (active) {
            Text(if (screen.phase == "streaming")
                "${screen.session.width} × ${screen.session.height} · ${screen.receivedFps.roundToInt()} fps · ${screen.mediaRoute} · ${if (screen.control) "Control" else "View only"}"
                else "${screen.phase.replaceFirstChar(Char::titlecase)}…",
                style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
        }
        if (specialKeys) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf(Triple("Ctrl", 2, 224), Triple("Alt", 4, 226), Triple("Shift", 1, 225), Triple("⌘", 8, 227)).forEach { (label, mask, hid) ->
                    FilterChip(selected = modifiers and mask != 0, enabled = screen.control, onClick = {
                        modifiers = modifiers xor mask; canvas?.modifiers = modifiers
                        controller.key(hid, modifiers and mask != 0, modifiers)
                    }, label = { Text(label) })
                }
                listOf("Esc" to 41, "Tab" to 43, "←" to 80, "↑" to 82, "↓" to 81, "→" to 79,
                    "Enter" to 40, "Backspace" to 42, "Delete" to 76, "Home" to 74, "End" to 77,
                    "PgUp" to 75, "PgDn" to 78).plus((1..12).map { "F$it" to (57 + it) }).forEach { (label, code) ->
                    OutlinedButton(enabled = screen.control, onClick = { canvas?.pressKey(code) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text(label) }
                }
            }
        }
        if (screen.capabilities.clipboardSupported) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilterChip(selected = screen.clipboardEnabled, enabled = screen.control, onClick = { controller.setClipboardEnabled(!screen.clipboardEnabled) },
                    label = { Text("Share clipboard") }, modifier = Modifier.testTag("screens.clipboard.toggle"))
                TextButton(enabled = screen.control && screen.clipboardEnabled && !screen.clipboardBusy, onClick = { controller.clipboard.copy() }, modifier = Modifier.testTag("screens.clipboard.copy")) { Text("Copy") }
                TextButton(enabled = screen.control && screen.clipboardEnabled && !screen.clipboardBusy, onClick = { controller.clipboard.paste() }, modifier = Modifier.testTag("screens.clipboard.paste")) { Text("Paste") }
            }
        }
        if (screen.clipboardError.isNotBlank()) Text(screen.clipboardError, color = MaterialTheme.colorScheme.error)
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                IconButton(enabled = screen.control, onClick = { keyboard = !keyboard; canvas?.showKeyboard(keyboard) }) { Icon(Icons.Outlined.Keyboard, "Toggle keyboard") }
                IconButton(enabled = screen.control, onClick = { specialKeys = !specialKeys }) { Icon(Icons.Outlined.KeyboardCommandKey, "Special keys") }
                TextButton(enabled = screen.control, onClick = { canvas?.click(Button.BUTTON_RIGHT) }) { Text("Right click") }
                IconButton(onClick = { canvas?.resetCanvas() }) { Icon(Icons.Outlined.FitScreen, "Fit screen") }
                IconButton(enabled = active, onClick = { controller.configure(refresh = true) }) { Icon(Icons.Outlined.Refresh, "Refresh screen") }
            }
        }
    }
    }
    if (help) AlertDialog(onDismissRequest = { help = false }, title = { Text("Screen gestures") }, text = {
        Text("One finger: move the cursor\nTap: left click\nDouble tap: double click\nHold, then move: drag\nTwo fingers: freely move and resize the canvas, including zooming out\nThree fingers: scroll the remote screen\n\nFit screen centers the entire desktop again. The bottom bar also opens the keyboard, modifier keys, and right click. Copy retrieves the remote selection; Paste inserts the phone clipboard. Share clipboard synchronizes text, images and files while this screen is focused (up to 8 MiB for images/files). Backgrounding releases held keys; returning reconnects automatically. Leaving Screens or Disconnect stops recovery.")
    }, confirmButton = { TextButton(onClick = { help = false }) { Text("Got it") } })
}

private tailrec fun Context.screenActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.screenActivity()
    else -> null
}
