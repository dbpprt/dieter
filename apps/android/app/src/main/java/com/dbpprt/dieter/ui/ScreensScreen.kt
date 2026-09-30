package com.dbpprt.dieter.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.lifecycle.viewmodel.compose.viewModel
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.screens.ScreenCapabilities
import com.dbpprt.dieter.core.screens.ScreenKeyboard
import com.dbpprt.dieter.screens.ScreenSessionViewModel
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.dbpprt.dieter.screens.ScreenCanvasView
import com.dbpprt.dieter.screens.ScreenHost
import com.dbpprt.dieter.core.screens.ScreenCanvas
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import kotlin.math.roundToInt

@Composable
fun ScreensScreen(state: DieterUiState, model: DieterViewModel, padding: PaddingValues) {
    val holder: ScreenSessionViewModel = viewModel()
    val host = remember(holder) { holder.host() }
    ScreenWorkspace(state.endpointConnections.filter { it.daemonId != null }, padding, host, onLeave = holder::leave)
}

@Composable
internal fun ScreenWorkspace(
    machines: List<com.dbpprt.dieter.core.machines.MachineRow>,
    padding: PaddingValues,
    host: ScreenHost,
    onLeave: () -> Unit = host::close,
) {
    val screen by host.view.collectAsStateWithLifecycle()
    val stats by host.stats.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current
    val activity = LocalContext.current.screenActivity()
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var canvas by remember { mutableStateOf<ScreenCanvasView?>(null) }
    var zoom by remember { mutableDoubleStateOf(host.canvas.zoom) }
    var fitted by remember { mutableStateOf(host.canvas.isFitted) }
    var machineMenu by remember { mutableStateOf(false) }
    var displayMenu by remember { mutableStateOf(false) }
    var qualityMenu by remember { mutableStateOf(false) }
    var help by remember { mutableStateOf(false) }
    var keyboard by remember { mutableStateOf(false) }
    var specialKeys by rememberSaveable { mutableStateOf(false) }
    var modifiers by remember { mutableIntStateOf(0) }
    val machine = machines.firstOrNull { it.id == selected }
    val active = screen.phase.active
    val streaming = screen.phase == ScreenPhase.Streaming
    val controlling = screen.controlActive
    val session = screen.state
    val capabilities = screen.capabilities
    fun disconnect() { canvas?.showKeyboard(false); keyboard = false; modifiers = 0; host.disconnect() }
    DisposableEffect(host, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) host.focus(false)
            if (event == Lifecycle.Event.ON_RESUME) host.resume()
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
        if (!screen.phase.active || screen.phase is ScreenPhase.Reconnecting) canvas?.resetSession()
    }
    LaunchedEffect(controlling) { if (!controlling) { modifiers = 0; canvas?.modifiers = 0 } }
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
                        }) }, enabled = endpoint.online,
                        onClick = { disconnect(); selected = endpoint.id; machineMenu = false },
                    ) }
                }
            }
            if (active) TextButton(onClick = ::disconnect, modifier = Modifier.testTag("screen-disconnect")) { Text("Disconnect") }
            else TextButton(enabled = machine?.online == true, onClick = {
                host.connect(requireNotNull(machine?.daemonId))
            }, modifier = Modifier.testTag("screen-connect")) { Text(if (screen.phase.problem != null) "Check Again" else "Connect") }
            if (active) {
                Box {
                    IconButton(onClick = { displayMenu = true }) { Icon(Icons.Outlined.DesktopWindows, "Choose display") }
                    DropdownMenu(displayMenu, { displayMenu = false }) {
                        capabilities?.displays.orEmpty().forEach { display -> DropdownMenuItem(
                            text = { Text(display.name.ifBlank { "Display ${display.id}" }) },
                            onClick = { host.selectDisplay(display.id); canvas?.resetCanvas(); displayMenu = false },
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
                            DropdownMenuItem(text = { Text(label) }, onClick = { host.selectQuality(value); qualityMenu = false })
                        }
                        HorizontalDivider()
                        listOf("Automatic codec" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO,
                            "H.264 compatibility" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
                            "HEVC · up to 1080p60" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC).forEach { (label, value) ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { host.selectCodec(value); qualityMenu = false })
                        }
                        HorizontalDivider()
                        ScreenCapabilities.frameRates(capabilities ?: RemoteDesktopCapabilities()).forEach { fps ->
                            DropdownMenuItem(text = { Text("Up to $fps fps") }, onClick = { host.selectMaxFps(fps); qualityMenu = false })
                        }
                    }
            }
            IconButton(onClick = { help = true }) { Icon(Icons.Outlined.HelpOutline, "Screen gestures") }
        }
        if (!session?.codec.isNullOrBlank()) Text(session?.codec.orEmpty() + (screen.codecFallbackReason?.let { " · $it" } ?: ""),
            style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 12.dp))
        screen.phase.problem?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp)) }
        if (!active && machine?.online == true && !machine.remoteDesktopReady) Text(
            machine.remoteDesktopReason.ifBlank { "This machine cannot host a screen session." },
            color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(12.dp),
        )
        if (machines.isEmpty()) Text("Connect an enrolled machine to view its screen.", modifier = Modifier.padding(16.dp))
        if (!active && screen.phase.problem == null) Text("Use this screen as a trackpad. Move the remote cursor with one finger; zoom and pan with two.",
            style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp))
        if (screen.canTransferControl) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                val hostControls = session?.control_active == true
                TextButton(enabled = !screen.controlTransferring, onClick = { host.transferControl(!hostControls) },
                    modifier = Modifier.testTag("screens.control")) {
                    Text(if (hostControls) "Release Control" else "Take Control")
                }
                Text("${session?.connected_clients ?: 0} viewers" + if (!hostControls && !session?.controller_name.isNullOrBlank())
                    " · ${session?.controller_name} controls" else "", style = MaterialTheme.typography.labelSmall)
            }
        }
        screen.controlError?.let { Text(it, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelSmall) }
        Column(Modifier.weight(1f).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            AndroidView(factory = { ScreenCanvasView(it, host).also { view ->
                canvas = view
                view.onCanvasChanged = { zoom = view.canvasModel.zoom; fitted = view.canvasModel.isFitted }
            } },
                update = { it.update(screen) },
                onRelease = { it.onCanvasChanged = null; it.release(); if (canvas === it) canvas = null },
                modifier = Modifier.weight(1f).fillMaxWidth().testTag("screen-canvas"))
            if (streaming) ScreenCanvasControls(
                zoom = zoom, fitted = fitted, onZoom = { canvas?.zoomCanvas(it) },
                onFit = { canvas?.resetCanvas(animated = true) },
                // Reserve space so controls never cover a remote dock or taskbar.
                modifier = Modifier.padding(vertical = 6.dp),
            )
        }
        if (active) {
            Text(if (streaming)
                "${session?.width ?: 0} × ${session?.height ?: 0} · ${stats.fps.roundToInt()} fps · ${stats.route} · ${if (controlling) "Control" else "View only"}"
                else "${screen.phase.label}…",
                style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
        }
        if (specialKeys) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScreenKeyboard.MODIFIER_KEYS.forEach { key ->
                    FilterChip(selected = modifiers and key.modifier != 0, enabled = controlling, onClick = {
                        modifiers = modifiers xor key.modifier; canvas?.modifiers = modifiers
                        host.key(key.hid, modifiers and key.modifier != 0, modifiers)
                    }, label = { Text(key.label) })
                }
                ScreenKeyboard.SPECIAL_KEYS.forEach { key ->
                    OutlinedButton(enabled = controlling, onClick = { canvas?.pressKey(key.hid) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text(key.label) }
                }
            }
        }
        if (capabilities?.clipboard_supported == true) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilterChip(selected = screen.clipboardEnabled, enabled = controlling, onClick = { host.setClipboardEnabled(!screen.clipboardEnabled) },
                    label = { Text("Share clipboard") }, modifier = Modifier.testTag("screens.clipboard.toggle"))
                TextButton(enabled = controlling && screen.clipboardEnabled && !screen.clipboardBusy, onClick = host::copy, modifier = Modifier.testTag("screens.clipboard.copy")) { Text("Copy") }
                TextButton(enabled = controlling && screen.clipboardEnabled && !screen.clipboardBusy, onClick = host::paste, modifier = Modifier.testTag("screens.clipboard.paste")) { Text("Paste") }
            }
        }
        screen.clipboardError?.takeIf(String::isNotBlank)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                IconButton(enabled = controlling, onClick = { keyboard = !keyboard; canvas?.showKeyboard(keyboard) }) { Icon(Icons.Outlined.Keyboard, "Toggle keyboard") }
                IconButton(enabled = controlling, onClick = { specialKeys = !specialKeys }) { Icon(Icons.Outlined.KeyboardCommandKey, "Special keys") }
                TextButton(enabled = controlling, onClick = { canvas?.click(Button.BUTTON_RIGHT) }) { Text("Right click") }
                TextButton(enabled = controlling, onClick = { canvas?.click() }) { Text("Click") }
                IconButton(enabled = active, onClick = host::refresh) { Icon(Icons.Outlined.Refresh, "Refresh screen") }
            }
        }
    }
    }
    if (help) AlertDialog(onDismissRequest = { help = false }, title = { Text("Screen gestures") }, text = {
        Text("Use the screen like a trackpad. Clicks happen at the cursor.\n\nOne finger: move the cursor\nTap: click at the cursor\nDouble tap: double click\nHold, then move: drag\nTwo fingers: zoom and pan around the point between your fingers\nThree fingers: scroll the remote screen\n\nUse − and + for precise zoom steps. Tap the zoom percentage to fit and center the desktop. 100% means fit to this window. You can also zoom out below 100%.\n\nThe bottom bar provides Click, Right click, and the keyboard. Share clipboard enables Copy and Paste for text, images and files. Backgrounding releases held input; returning reconnects automatically.",
            modifier = Modifier.verticalScroll(rememberScrollState()))
    }, confirmButton = { TextButton(onClick = { help = false }) { Text("Got it") } })
}

@Composable
internal fun ScreenCanvasControls(
    zoom: Double, fitted: Boolean, onZoom: (Double) -> Unit, onFit: () -> Unit, modifier: Modifier = Modifier,
) {
    Surface(modifier, shape = RoundedCornerShape(28.dp), tonalElevation = 6.dp, shadowElevation = 3.dp,
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = .96f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { onZoom(1 / 1.25) }, enabled = zoom > ScreenCanvas.MIN_ZOOM + .001,
                modifier = Modifier.testTag("screen-zoom-out")) { Icon(Icons.Outlined.Remove, "Zoom out") }
            TextButton(onClick = onFit, modifier = Modifier.widthIn(min = 112.dp).testTag("screen-fit").semantics {
                contentDescription = "Fit screen. Current zoom ${(zoom * 100).roundToInt()} percent"
            }) {
                Icon(Icons.Outlined.FitScreen, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(if (fitted) "Fit · 100%" else "${(zoom * 100).roundToInt()}%")
            }
            IconButton(onClick = { onZoom(1.25) }, enabled = zoom < ScreenCanvas.MAX_ZOOM - .001,
                modifier = Modifier.testTag("screen-zoom-in")) { Icon(Icons.Outlined.Add, "Zoom in") }
        }
    }
}

private tailrec fun Context.screenActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.screenActivity()
    else -> null
}
