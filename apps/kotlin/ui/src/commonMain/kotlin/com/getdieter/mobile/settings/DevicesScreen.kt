package com.getdieter.mobile.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.client.rules.DeviceExports
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.store.*
import com.getdieter.mobile.tools.machineGlyph

/** The account's trusted devices: add one by its code, remove one, and this device's trust. */
@Composable
internal fun DevicesScreen(store: MobileStore) {
    val view by store.devices.slice.collectAsState()
    val busy by store.busy.collectAsState()
    val approvalError by store.devices.approvalError.collectAsState()
    var code by remember { mutableStateOf(TextFieldValue("")) }
    var removing by remember { mutableStateOf<DeviceEntry?>(null) }
    var resetting by remember { mutableStateOf(false) }
    ShowDevices(store)
    val complete = DeviceExports.pairingCodeComplete(code.text)
    fun approve() {
        if (complete && !busy) store.devices.approve(code.text) { code = TextFieldValue("") }
    }
    val active = view.devices.filter { !it.revoked }
    val removed = view.devices.filter { it.revoked }
    Screen(
        ScreenChrome(
            "Devices",
            actions =
                listOf(
                    ChromeAction(
                        "refresh-devices",
                        "Refresh",
                        Glyph.REFRESH,
                        enabled = !view.loading,
                        onClick = store.devices::refresh,
                    )
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("devices"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.title.isNotEmpty())
                item("status") {
                    Banner(
                        view.title,
                        view.detail,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = view.trust.tone,
                        glyph = view.trust.glyph,
                    )
                }
            if (view.pairing_code.isNotEmpty())
                item("code") {
                    PairingCode(
                        view.pairing_code,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    )
                }
            if (view.error.isNotEmpty())
                item("error") {
                    Banner(
                        view.error,
                        "",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                    )
                }
            if (view.trust == DeviceTrust.DEVICE_TRUST_TRUSTED)
                item("add") {
                    SectionHeader("Add a device")
                    Column(
                        Modifier.padding(horizontal = ScreenMargin),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        MobileTextField(
                            code,
                            { typed ->
                                // The core groups and corrects what is typed; a reformatted
                                // code keeps the cursor at its end.
                                val shown = DeviceExports.pairingCodeInput(typed.text)
                                if (shown != code.text) store.devices.approvalError.value = ""
                                code =
                                    if (shown == typed.text) typed
                                    else TextFieldValue(shown, TextRange(shown.length))
                            },
                            Modifier.fillMaxWidth().testTag("pairing-code-input"),
                            textStyle = type.body.copy(fontFamily = FontFamily.Monospace),
                            label = { Text("Code shown on the new device") },
                            placeholder = { Text("ABCD-EFGH-JKMN-PQRS") },
                            supportingText = {
                                if (approvalError.isNotEmpty())
                                    Text(approvalError, color = palette.destructive)
                                else
                                    Text(
                                        "Only type a code your own new device shows: an " +
                                            "approved device gets full access to your machines."
                                    )
                            },
                            singleLine = true,
                            keyboardOptions =
                                KeyboardOptions(
                                    capitalization = KeyboardCapitalization.Characters,
                                    autoCorrectEnabled = false,
                                    keyboardType = KeyboardType.Ascii,
                                    imeAction = ImeAction.Done,
                                ),
                            keyboardActions = KeyboardActions(onDone = { approve() }),
                        )
                        DButton(
                            "Approve",
                            ::approve,
                            Modifier.fillMaxWidth().testTag("approve-device"),
                            enabled = complete,
                            loading = busy && complete,
                        )
                    }
                }
            if (view.requests.isNotEmpty())
                item("waiting") {
                    SectionHeader("Waiting devices")
                    Group(view.requests) { request, position ->
                        ListRow(
                            request.name,
                            Modifier.testTag("waiting-device"),
                            position = position,
                            subtitle = describe(request.kind_label, request.platform),
                            glyph = deviceGlyph(request.platform, ""),
                        )
                    }
                }
            if (active.isNotEmpty())
                item("devices") {
                    SectionHeader("Devices")
                    Group(active) { device, position ->
                        DeviceRow(device, position) { removing = device }
                    }
                }
            if (removed.isNotEmpty())
                item("removed") {
                    SectionHeader("Removed")
                    Group(removed) { device, position -> DeviceRow(device, position) {} }
                }
            if (view.notices.isNotEmpty())
                item("notices") {
                    SectionHeader("Recent changes")
                    Group(view.notices) { notice, position ->
                        ListRow(
                            notice.text,
                            position = position,
                            glyph = Glyph.HISTORY,
                            titleMaxLines = 3,
                        )
                    }
                }
            if (view.trust.resettable)
                item("reset") {
                    SectionHeader("This device")
                    ListRow(
                        "Reset this device",
                        Modifier.testTag("reset-device"),
                        destructive = true,
                        glyph = Glyph.UNDO,
                        onClick = { resetting = true },
                    )
                }
        }
    }
    removing?.let { device ->
        ConfirmDialog(
            if (device.this_device) "Remove this device?" else "Remove ${device.name}?",
            if (device.this_device)
                "This device can no longer reach your machines until a trusted device adds it again."
            else "${device.name} can no longer reach your machines until it is added again.",
            "Remove",
            {
                store.devices.remove(device.device_id)
                removing = null
            },
            { removing = null },
            destructive = true,
        )
    }
    if (resetting) ResetDeviceDialog(store) { resetting = false }
}

/**
 * What the app shows instead of machine content until this device is trusted: its code while it
 * waits for approval, or why it cannot connect and how to recover.
 */
@Composable
internal fun PairingScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val view by store.devices.slice.collectAsState()
    val busy by store.busy.collectAsState()
    val error by store.error.collectAsState()
    var resetting by remember { mutableStateOf(false) }
    var signingOut by remember { mutableStateOf(false) }
    ShowDevices(store)
    val trust = session.device_trust
    // The devices slice words the state; it can trail the session by one update.
    val current = view.trust == trust
    Box(
        Modifier.fillMaxSize()
            .background(palette.background)
            .safeDrawingPadding()
            .testTag("pairing"),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.widthIn(max = 440.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.size(72.dp).background(palette.accent, RoundedCornerShape(20.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(trust.glyph, null, tint = palette.onAccent, size = 36.dp)
            }
            Spacer(Modifier.height(24.dp))
            if (current) {
                Text(
                    view.title,
                    Modifier.testTag("pairing-title"),
                    style = type.title1,
                    color = palette.label,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    view.detail,
                    style = type.body,
                    color = palette.secondaryLabel,
                    textAlign = TextAlign.Center,
                )
            }
            if (trust == DeviceTrust.DEVICE_TRUST_PENDING && session.pairing_code.isNotEmpty()) {
                Spacer(Modifier.height(28.dp))
                PairingCode(session.pairing_code, Modifier.fillMaxWidth())
                Spacer(Modifier.height(20.dp))
                Spinner()
            }
            if (trust.resettable) {
                Spacer(Modifier.height(28.dp))
                DButton(
                    "Reset this device",
                    { resetting = true },
                    Modifier.fillMaxWidth().testTag("reset-device"),
                    kind = ButtonKind.DESTRUCTIVE,
                    large = true,
                    loading = busy,
                )
            }
            listOf(view.error.takeIf { current }.orEmpty(), error)
                .filter { it.isNotEmpty() }
                .distinct()
                .forEach {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        it,
                        style = type.footnote,
                        color = palette.destructive,
                        textAlign = TextAlign.Center,
                    )
                }
            Spacer(Modifier.height(20.dp))
            DButton(
                "Sign out",
                { signingOut = true },
                Modifier.testTag("pairing-sign-out"),
                kind = ButtonKind.PLAIN,
            )
        }
    }
    if (resetting) ResetDeviceDialog(store) { resetting = false }
    if (signingOut) SignOutDialog(store) { signingOut = false }
}

/**
 * This device's one-time code, large and selectable, and the command a machine approves it with.
 */
@Composable
internal fun PairingCode(code: String, modifier: Modifier = Modifier) {
    val clipboard = LocalClipboardManager.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(if (apple) 18.dp else 16.dp))
            .background(if (apple) palette.cell else colors.surfaceContainerHigh)
            .padding(horizontal = 16.dp, vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        SelectionContainer {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    code,
                    Modifier.testTag("pairing-code"),
                    style =
                        type.title2.copy(
                            fontFamily = FontFamily.Monospace,
                            fontWeight = FontWeight.SemiBold,
                        ),
                    color = palette.label,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "dieter device approve $code",
                    style = type.monoSmall,
                    color = palette.secondaryLabel,
                    textAlign = TextAlign.Center,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        DButton(
            "Copy",
            { clipboard.setText(AnnotatedString(code)) },
            Modifier.testTag("copy-pairing-code"),
            kind = ButtonKind.PLAIN,
            glyph = Glyph.COPY,
        )
    }
}

@Composable
private fun DeviceRow(device: DeviceEntry, position: Position, remove: () -> Unit) {
    ListRow(
        device.name,
        Modifier.testTag(if (device.this_device) "device-this" else "device-row"),
        position = position,
        subtitle =
            listOf(
                    describe(device.kind_label, device.platform),
                    device.added_by.takeIf { it.isNotEmpty() }?.let { "Added by $it" }.orEmpty(),
                )
                .filter { it.isNotEmpty() }
                .joinToString("\n"),
        value = if (device.this_device) "This device" else null,
        glyph = deviceGlyph(device.platform, device.daemon_id),
        enabled = !device.revoked,
        trailing =
            if (device.revocable)
                ({
                    DButton(
                        "Remove",
                        remove,
                        Modifier.testTag("device-remove"),
                        kind = ButtonKind.PLAIN,
                    )
                })
            else null,
    )
}

/** Holds the core's devices view (and its polling of waiting devices) while shown. */
@Composable
private fun ShowDevices(store: MobileStore) {
    DisposableEffect(store) {
        val release = store.devices.show()
        onDispose { release() }
    }
}

@Composable
private fun ResetDeviceDialog(store: MobileStore, onDismiss: () -> Unit) {
    ConfirmDialog(
        "Reset this device?",
        "This device forgets your trusted devices and its key, then shows a new code. Remove it " +
            "from your account on a trusted device if it is still listed there.",
        "Reset",
        {
            store.devices.reset()
            onDismiss()
        },
        onDismiss,
        destructive = true,
    )
}

private fun describe(kindLabel: String, platform: String) =
    listOf(kindLabel, platform).filter { it.isNotBlank() }.joinToString(" · ")

private fun deviceGlyph(platform: String, daemonId: String): Glyph =
    when {
        daemonId.isNotEmpty() -> machineGlyph(platform)
        platform == "recovery" -> Glyph.KEY
        platform == "android" || platform == "ios" -> Glyph.PHONE
        else -> Glyph.MACHINE
    }

private val DeviceTrust.resettable: Boolean
    get() = this == DeviceTrust.DEVICE_TRUST_REVOKED || this == DeviceTrust.DEVICE_TRUST_CONFLICT

private val DeviceTrust.tone: Tone
    get() =
        when (this) {
            DeviceTrust.DEVICE_TRUST_TRUSTED -> Tone.SUCCESS
            DeviceTrust.DEVICE_TRUST_REVOKED,
            DeviceTrust.DEVICE_TRUST_CONFLICT -> Tone.DANGER
            DeviceTrust.DEVICE_TRUST_NO_ROSTER,
            DeviceTrust.DEVICE_TRUST_PENDING -> Tone.WARNING
            else -> Tone.NEUTRAL
        }

private val DeviceTrust.glyph: Glyph
    get() =
        when (this) {
            DeviceTrust.DEVICE_TRUST_TRUSTED -> Glyph.LOCK
            DeviceTrust.DEVICE_TRUST_PENDING -> Glyph.KEY
            DeviceTrust.DEVICE_TRUST_NO_ROSTER -> Glyph.MACHINE
            DeviceTrust.DEVICE_TRUST_REVOKED,
            DeviceTrust.DEVICE_TRUST_CONFLICT -> Glyph.WARNING
            else -> Glyph.SYNC
        }
