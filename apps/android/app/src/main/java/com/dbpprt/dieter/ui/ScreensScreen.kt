package com.dbpprt.dieter.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton.Button
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.core.machines.MachineRow
import com.dbpprt.dieter.core.machines.MachineRows
import com.dbpprt.dieter.core.screens.*
import com.dbpprt.dieter.screens.ScreenCanvasView
import com.dbpprt.dieter.screens.ScreenHost
import com.dbpprt.dieter.screens.ScreenSessionViewModel
import kotlin.math.roundToInt

@Composable
fun ScreensScreen(state: DieterUiState, padding: PaddingValues) {
    val holder: ScreenSessionViewModel = viewModel()
    val host = remember(holder) { holder.host() }
    ScreenWorkspace(state.presentedEndpointConnections, padding, host, onLeave = holder::leave)
}

/** Zoom changes recompose the small controls, rather than the entire session on every touch frame. */
@Stable
private class CanvasControlsState {
    var zoom by mutableDoubleStateOf(1.0)
    var fitted by mutableStateOf(true)
    fun update(canvas: ScreenCanvas) { zoom = canvas.zoom; fitted = canvas.isFitted }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ScreenWorkspace(
    machines: List<MachineRow>,
    padding: PaddingValues,
    host: ScreenHost,
    onLeave: () -> Unit = host::close,
) {
    val screen by host.view.collectAsStateWithLifecycle()
    val stats by host.stats.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current
    val activity = LocalContext.current.screenActivity()
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedDaemon by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedName by rememberSaveable { mutableStateOf("") }
    var canvas by remember { mutableStateOf<ScreenCanvasView?>(null) }
    val controls = remember(host) { CanvasControlsState().apply { update(host.canvas) } }
    var displayMenu by remember { mutableStateOf(false) }
    var qualityMenu by remember { mutableStateOf(false) }
    var help by remember { mutableStateOf(false) }
    var information by remember { mutableStateOf(false) }
    var specialKeys by rememberSaveable { mutableStateOf(false) }
    var modifiers by remember { mutableIntStateOf(0) }
    // Floating and hardware-keyboard accessory IMEs can be visible with zero bottom inset.
    val keyboard = WindowInsets.isImeVisible
    val machine = machines.firstOrNull { it.id == selected }
    val streaming = screen.phase == ScreenPhase.Streaming
    val controlling = screen.controlActive
    val capabilities = screen.capabilities
    fun disconnect() {
        canvas?.showKeyboard(false); modifiers = 0
        host.disconnect(); host.canvas.reset()
        selected = null; selectedDaemon = null
    }
    fun connect(machine: MachineRow) {
        selected = machine.id; selectedDaemon = machine.daemonId; selectedName = machine.label
        host.canvas.reset()
        if (machine.remoteDesktopReady) host.connect(requireNotNull(machine.daemonId))
    }
    DisposableEffect(activity) {
        val window = activity?.window
        val previous = window?.attributes?.softInputMode
        // Edge-to-edge windows need adjustResize to dispatch IME insets. The
        // canvas ignores those insets; only the accessory layer moves with them.
        if (window != null && previous != null) window.setSoftInputMode(
            (previous and WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST.inv()) or WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        onDispose { if (window != null && previous != null) window.setSoftInputMode(previous) }
    }
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
    BackHandler(selected != null) { if (information) information = false else if (keyboard) canvas?.showKeyboard(false) else disconnect() }
    LaunchedEffect(screen.phase) {
        // Recovery can change session identity, but the user's view stays put.
        if (!screen.phase.active || screen.phase is ScreenPhase.Reconnecting) canvas?.clearFrame()
    }
    LaunchedEffect(controlling) { if (!controlling) { modifiers = 0; canvas?.modifiers = 0 } }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
      Box(Modifier.fillMaxSize()) {
        if (selected == null) {
            ScreenMachineList(machines, Modifier.fillMaxSize().padding(padding), ::connect)
        } else {
            Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                // Fixed-height chrome: changing status, routes, FPS and presence cannot resize the canvas.
                Row(Modifier.fillMaxWidth().heightIn(min = 72.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = ::disconnect, modifier = Modifier.testTag("screen-disconnect")) {
                        Icon(Icons.Outlined.ArrowBack, "Disconnect and choose machine")
                    }
                    Column(Modifier.weight(1f)) {
                        Text(machine?.label ?: selectedName, style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Box(Modifier.size(7.dp).background(if (streaming) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.tertiary, CircleShape))
                            Text(screen.statusLine,
                                style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.testTag("screen-status"))
                        }
                    }
                    IconButton(onClick = { information = true }) { Icon(Icons.Outlined.Info, "Connection details") }
                    Box {
                        IconButton(onClick = { qualityMenu = true }) { Icon(Icons.Outlined.Tune, "Screen quality") }
                        ScreenQualityMenu(qualityMenu, { qualityMenu = false }, screen.frameRates, host)
                    }
                }
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(screen.metadata(stats.fps, stats.route),
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).testTag("screen-metadata"))
                    Box {
                        IconButton(onClick = { displayMenu = true }, enabled = capabilities?.displays?.isNotEmpty() == true) {
                            Icon(Icons.Outlined.DesktopWindows, "Choose display", Modifier.size(18.dp))
                        }
                        DropdownMenu(displayMenu, { displayMenu = false }) {
                            capabilities?.displays.orEmpty().forEach { display -> DropdownMenuItem(
                                text = { Text(display.name.ifBlank { "Display ${display.id}" }) },
                                onClick = { host.selectDisplay(display.id); canvas?.resetCanvas(); displayMenu = false }) }
                        }
                    }
                }
                Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                    .background(Color(0xFF0C0F14))) {
                    // Only the accessory layer consumes IME insets. Keyboard and
                    // key-row visibility never enter the desktop's measurement.
                    AndroidView(factory = { ScreenCanvasView(it, host).also { view ->
                        canvas = view; view.onCanvasChanged = { controls.update(view.canvasModel) }
                    } }, update = { it.update(screen) },
                        onRelease = { it.onCanvasChanged = null; it.release(); if (canvas === it) canvas = null },
                        modifier = Modifier.fillMaxSize().padding(bottom = 64.dp).testTag("screen-canvas"))
                    if (!streaming) {
                        Column(Modifier.align(Alignment.Center).padding(28.dp).widthIn(max = 420.dp), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            if (screen.phase.active) CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp)
                            Text(screen.waitingMessage(machine?.remoteDesktopReady != false, machine?.remoteDesktopReason.orEmpty()),
                                color = Color.White, style = MaterialTheme.typography.bodyMedium)
                            if (!screen.phase.active) Button(enabled = machine?.canShareScreen == true && selectedDaemon != null,
                                onClick = { selectedDaemon?.let(host::connect) }, modifier = Modifier.testTag("screen-connect")) { Text("Check again") }
                        }
                    }
                    if (streaming && !keyboard) CanvasZoomControls(controls, canvas,
                        Modifier.align(Alignment.BottomCenter).padding(bottom = 76.dp))
                    Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().imePadding()) {
                        if (specialKeys) ScreenSpecialKeys(controlling, modifiers, onModifier = { mask, hid ->
                            modifiers = modifiers xor mask; canvas?.modifiers = modifiers
                            host.key(hid, modifiers and mask != 0, modifiers)
                        }, onKey = { canvas?.pressKey(it) })
                        Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, tonalElevation = 4.dp) {
                            Row(Modifier.fillMaxWidth().height(64.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                                IconButton(enabled = controlling, onClick = { canvas?.showKeyboard(!keyboard) }, modifier = Modifier.testTag("screen-keyboard")) {
                                    Icon(if (keyboard) Icons.Outlined.KeyboardHide else Icons.Outlined.Keyboard, if (keyboard) "Hide keyboard" else "Show keyboard")
                                }
                                IconToggleButton(checked = specialKeys, enabled = controlling, onCheckedChange = { specialKeys = it }) {
                                    Icon(Icons.Outlined.KeyboardCommandKey, "Special keys")
                                }
                                TextButton(enabled = controlling, onClick = { canvas?.click(Button.BUTTON_RIGHT) }) { Text("Right click") }
                                TextButton(enabled = controlling, onClick = { canvas?.pressKey(ScreenKeyboard.ENTER) }, modifier = Modifier.testTag("screen-enter")) { Text("Enter") }
                                IconButton(onClick = { help = true }) { Icon(Icons.Outlined.HelpOutline, "Screen gestures") }
                            }
                        }
                    }
                }
            }
        }
        // An in-window details surface keeps keyboard/control ownership intact.
        if (information) Surface(Modifier.fillMaxSize().padding(padding), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Connection details", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = { information = false }) { Text("Done") }
            }
            val details = screen.details(selectedDaemon.orEmpty(), stats.fps, stats.route)
            Text(machine?.label ?: selectedName, style = MaterialTheme.typography.titleMedium)
            Text(details.status)
            Text(details.video)
            Text(screen.latencyLabel)
            Text(details.signaling)
            Text(details.machine, style = MaterialTheme.typography.bodySmall)
            details.session.forEach { Text(it) }
            machine?.releaseLabel?.takeIf { it.isNotBlank() }?.let { Text(it) }
            screen.codecFallbackReason?.let { Text(it) }
            if (screen.canTransferControl) TextButton(enabled = !screen.controlTransferring, onClick = { host.transferControl(!controlling) }, modifier = Modifier.testTag("screens.control")) {
                Text(screen.controlAction)
            }
            screen.controlUnavailableReason.takeIf { it.isNotEmpty() }?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            screen.controlError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (capabilities?.clipboard_supported == true) {
                FilterChip(selected = screen.clipboardEnabled, enabled = controlling, onClick = { host.setClipboardEnabled(!screen.clipboardEnabled) },
                    label = { Text("Share clipboard") }, modifier = Modifier.testTag("screens.clipboard.toggle"))
                Row {
                    TextButton(enabled = screen.clipboardActionsEnabled, onClick = host::copy, modifier = Modifier.testTag("screens.clipboard.copy")) { Text("Copy") }
                    TextButton(enabled = screen.clipboardActionsEnabled, onClick = host::paste, modifier = Modifier.testTag("screens.clipboard.paste")) { Text("Paste") }
                }
                screen.clipboardError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
            TextButton(enabled = screen.phase.active, onClick = host::refresh) { Text("Refresh screen") }
        }
        }
      }
    }
    if (help) AlertDialog(onDismissRequest = { help = false }, title = { Text("Your phone is a trackpad") }, text = {
        Text("One finger moves the cursor. Tap to click, double tap to double click, or hold and move to drag.\n\nTwo fingers zoom and pan around the point between them. Three fingers scroll the remote screen.\n\nUse − and + for smooth zoom steps. Fit centers the desktop; 100% means fit to this window.\n\nThe keyboard overlays the desktop without changing its scale. Pan with two fingers to reveal anything behind it. Enter works from the keyboard or the bottom bar.\n\nConnection details shows the video route, display, codec, control and clipboard options.", Modifier.verticalScroll(rememberScrollState()))
    }, confirmButton = { TextButton(onClick = { help = false }) { Text("Got it") } })
}

@Composable
private fun CanvasZoomControls(state: CanvasControlsState, canvas: ScreenCanvasView?, modifier: Modifier) {
    ScreenCanvasControls(state.zoom, state.fitted, { canvas?.zoomCanvas(it) }, { canvas?.resetCanvas(animated = true) }, modifier)
}

@Composable
internal fun ScreenMachineList(machines: List<MachineRow>, modifier: Modifier = Modifier, onConnect: (MachineRow) -> Unit) {
    val ordered = remember(machines) { MachineRows.listed(machines) }
    LazyColumn(modifier.testTag("screen-machines"), contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Column(Modifier.padding(top = 12.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Outlined.DesktopWindows, null, Modifier.size(34.dp), tint = MaterialTheme.colorScheme.primary)
                Text("Your screens", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
                Text("Choose a machine to connect. Your phone becomes its trackpad and keyboard.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        items(ordered, key = { it.id }) { machine ->
            val enabled = machine.canShareScreen
            OutlinedCard(onClick = { onConnect(machine) }, enabled = enabled, shape = RoundedCornerShape(20.dp),
                colors = CardDefaults.outlinedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant), modifier = Modifier.fillMaxWidth().testTag("screen-machine-${machine.id}")) {
                Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                        Icon(Icons.Outlined.Computer, null, Modifier.padding(12.dp).size(24.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer)
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(machine.label, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(machine.screenStatus,
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        val metadata = machine.screenMetadata
                        if (metadata.isNotBlank()) Text(metadata, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Icon(Icons.Outlined.ChevronRight, if (enabled) "Connect to ${machine.label}" else null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (ordered.isEmpty()) item { Text("Connect an enrolled machine to view its screen.", color = MaterialTheme.colorScheme.onSurfaceVariant) }
        item { Text("One finger to point · Two fingers to zoom", style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp)) }
    }
}

@Composable
private fun ScreenSpecialKeys(enabled: Boolean, modifiers: Int, onModifier: (Int, Int) -> Unit, onKey: (Int) -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ScreenKeyboard.MODIFIER_KEYS.forEach { key -> FilterChip(selected = modifiers and key.modifier != 0, enabled = enabled,
                onClick = { onModifier(key.modifier, key.hid) }, label = { Text(key.label) }) }
            ScreenKeyboard.SPECIAL_KEYS.forEach { key -> OutlinedButton(enabled = enabled, onClick = { onKey(key.hid) }, contentPadding = PaddingValues(horizontal = 12.dp)) { Text(key.label) } }
        }
    }
}

@Composable
private fun ScreenQualityMenu(expanded: Boolean, dismiss: () -> Unit, frameRates: List<Int>, host: ScreenHost) {
    DropdownMenu(expanded, dismiss) {
        listOf("Auto" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_AUTO, "Detail" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL,
            "Responsive motion" to RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION).forEach { (label, value) ->
            DropdownMenuItem(text = { Text(label) }, onClick = { host.selectQuality(value); dismiss() })
        }
        HorizontalDivider()
        listOf("Automatic codec" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO,
            "H.264 compatibility" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
            "HEVC · up to 1080p60" to RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC).forEach { (label, value) ->
            DropdownMenuItem(text = { Text(label) }, onClick = { host.selectCodec(value); dismiss() })
        }
        HorizontalDivider()
        frameRates.forEach { fps ->
            DropdownMenuItem(text = { Text("Up to $fps fps") }, onClick = { host.selectMaxFps(fps); dismiss() })
        }
    }
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
