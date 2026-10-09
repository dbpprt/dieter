@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Native presentations for one iOS screen: UIMenu, UIAlertController and sheets. */
internal interface NativeOverlays {
    /** [x], [y], [width] and [height] are points in the screen's Compose view. */
    fun showMenu(
        sections: List<MenuSection>,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        onDismiss: () -> Unit,
    )

    fun confirm(
        title: String,
        message: String,
        confirm: String,
        destructive: Boolean,
        onConfirm: () -> Unit,
        onCancel: () -> Unit,
    )

    fun prompt(
        title: String,
        message: String,
        value: String,
        placeholder: String,
        confirm: String,
        onConfirm: (String) -> Unit,
        onCancel: () -> Unit,
    )

    fun presentSheet(
        title: String,
        size: SheetSize,
        chrome: State<ScreenChrome>,
        content: State<@Composable () -> Unit>,
        onDismiss: () -> Unit,
    ): AutoCloseable
}

internal val LocalNativeOverlays = staticCompositionLocalOf<NativeOverlays?> { null }

internal enum class SheetSize {
    MEDIUM,
    LARGE,
}

@Stable
internal class MenuState {
    var sections by mutableStateOf<List<MenuSection>?>(null)
    internal var bounds = Rect.Zero

    fun show(sections: List<MenuSection>) {
        this.sections = sections
    }

    fun dismiss() {
        sections = null
    }
}

@Composable internal fun rememberMenuState() = remember { MenuState() }

/** Anchors a menu to its content: a native UIMenu on iOS, a Material dropdown on Android. */
@Composable
internal fun MenuAnchor(
    state: MenuState,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val overlays = LocalNativeOverlays.current
    val density = LocalDensity.current.density
    Box(modifier.onGloballyPositioned { state.bounds = it.boundsInWindow() }) {
        content()
        val sections = state.sections
        if (overlays == null) MaterialMenu(sections.orEmpty(), sections != null, state::dismiss)
        else if (sections != null)
            LaunchedEffect(sections) {
                val bounds = state.bounds
                overlays.showMenu(
                    sections,
                    bounds.left / density.toDouble(),
                    bounds.top / density.toDouble(),
                    bounds.width / density.toDouble(),
                    bounds.height / density.toDouble(),
                    state::dismiss,
                )
            }
    }
}

/** A "…" button that opens a menu. */
@Composable
internal fun MenuButton(
    sections: List<MenuSection>,
    contentDescription: String,
    modifier: Modifier = Modifier,
    glyph: Glyph = if (apple) Glyph.MORE_HORIZONTAL else Glyph.MORE,
    plain: Boolean = true,
) {
    val state = rememberMenuState()
    MenuAnchor(state, modifier) {
        if (apple && plain)
            Box(
                Modifier.size(36.dp)
                    .pressable(onClick = { state.show(sections) })
                    .testTag("menu-button"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    glyph,
                    contentDescription,
                    tint = palette.secondaryLabel,
                    size = 20.dp,
                    weight = GlyphWeight.MEDIUM,
                )
            }
        else
            CircleButton(
                glyph,
                contentDescription,
                { state.show(sections) },
                Modifier.testTag("menu-button"),
            )
    }
}

/** A confirmation alert. Native UIAlertController on iOS. */
@Composable
internal fun ConfirmDialog(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
) {
    val overlays = LocalNativeOverlays.current
    val confirmed by rememberUpdatedState(onConfirm)
    val dismissed by rememberUpdatedState(onDismiss)
    if (overlays != null) {
        LaunchedEffect(title, message) {
            overlays.confirm(title, message, confirm, destructive, { confirmed() }, { dismissed() })
        }
        return
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text =
            if (message.isNotEmpty()) {
                { Text(message) }
            } else null,
        confirmButton = {
            TextButton(
                {
                    onConfirm()
                },
                Modifier.testTag("dialog-confirm"),
                colors =
                    if (destructive) ButtonDefaults.textButtonColors(contentColor = colors.error)
                    else ButtonDefaults.textButtonColors(),
            ) {
                Text(confirm)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}

/** Single text input alert, e.g. rename. */
@Composable
internal fun PromptDialog(
    title: String,
    initial: String,
    confirm: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
    message: String = "",
    placeholder: String = "",
) {
    val overlays = LocalNativeOverlays.current
    val confirmed by rememberUpdatedState(onConfirm)
    val dismissed by rememberUpdatedState(onDismiss)
    if (overlays != null) {
        LaunchedEffect(title) {
            overlays.prompt(
                title,
                message,
                initial,
                placeholder,
                confirm,
                { confirmed(it) },
                { dismissed() },
            )
        }
        return
    }
    var value by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (message.isNotEmpty()) Text(message)
                OutlinedTextField(
                    value,
                    { value = it },
                    singleLine = true,
                    placeholder = { Text(placeholder) },
                    modifier = Modifier.fillMaxWidth().testTag("dialog-input"),
                    keyboardOptions = KeyboardOptions.Default,
                )
            }
        },
        confirmButton = {
            TextButton(
                { onConfirm(value) },
                enabled = value.isNotBlank(),
                modifier = Modifier.testTag("dialog-confirm"),
            ) {
                Text(confirm)
            }
        },
        dismissButton = { TextButton(onDismiss) { Text("Cancel") } },
    )
}

/**
 * A modal sheet. iOS presents a native sheet (grabber, detents, glass close and confirm buttons)
 * hosting this Compose content; Android uses a Material modal bottom sheet.
 */
@Composable
internal fun Sheet(
    title: String,
    onDismiss: () -> Unit,
    size: SheetSize = SheetSize.LARGE,
    confirm: ChromeAction? = null,
    scrollable: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val overlays = LocalNativeOverlays.current
    val dismissed by rememberUpdatedState(onDismiss)
    val body: @Composable () -> Unit = {
        Column(
            Modifier.fillMaxWidth()
                .then(if (scrollable) Modifier.verticalScroll(rememberScrollState()) else Modifier)
                .padding(bottom = 24.dp),
            content = content,
        )
    }
    if (overlays != null) {
        val chrome = rememberUpdatedState(ScreenChrome(title, confirm = confirm))
        val current = rememberUpdatedState(body)
        DisposableEffect(overlays) {
            val handle = overlays.presentSheet(title, size, chrome, current) { dismissed() }
            onDispose { handle.close() }
        }
        return
    }
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = size == SheetSize.LARGE)
    ModalBottomSheet(onDismiss, sheetState = state, containerColor = colors.surfaceContainerLow) {
        Row(
            Modifier.fillMaxWidth().padding(start = 24.dp, end = 16.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, Modifier.weight(1f), style = type.title2, color = palette.label)
            confirm?.let {
                Button(
                    it.onClick,
                    enabled = it.enabled,
                    modifier = Modifier.testTag("sheet-${it.id}"),
                ) {
                    Text(it.title)
                }
            }
        }
        body()
    }
}

/** Form section heading used inside sheets and editors. */
@Composable
internal fun FormLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        if (apple) text.uppercase() else text,
        modifier.padding(start = if (apple) 16.dp else 4.dp, bottom = 6.dp, top = 4.dp),
        style =
            if (apple) type.footnote
            else MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Medium),
        color = if (apple) palette.secondaryLabel else colors.primary,
    )
}
