package com.getdieter.mobile.folders

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.DirectoryListing
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.CancellationException

/**
 * Browses [daemonId]'s directories (the daemon's `ListDirectories`, as the Mac's project picker
 * does) starting at [initial] or its home, and picks one.
 */
@Composable
internal fun DaemonDirectoryPicker(
    store: MobileStore,
    daemonId: String,
    initial: String,
    onPick: (String) -> Unit,
    dismiss: () -> Unit,
) {
    var path by remember { mutableStateOf(initial.trim()) }
    var listing by remember { mutableStateOf<DirectoryListing?>(null) }
    var error by remember { mutableStateOf("") }
    var hidden by remember { mutableStateOf(false) }
    LaunchedEffect(daemonId, path) {
        error = ""
        try {
            listing = store.folders.directories(daemonId, path)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            error = failure.message ?: "The directories could not be listed."
            if (listing == null && path.isNotEmpty()) path = ""
        }
    }
    val shown = listing
    Sheet(
        "Choose a directory",
        dismiss,
        confirm =
            ChromeAction(
                "pick-directory",
                "Choose",
                Glyph.CHECK,
                enabled = shown?.path?.isNotEmpty() == true,
            ) {
                shown?.path?.let(onPick)
                dismiss()
            },
    ) {
        if (shown == null && error.isEmpty())
            Box(Modifier.fillMaxWidth().padding(32.dp), Alignment.Center) { Spinner() }
        if (error.isNotEmpty())
            Banner(
                "Not available",
                error,
                Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                tone = Tone.WARNING,
            )
        if (shown != null) {
            Text(
                shown.path,
                Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 8.dp)
                    .testTag("directory-path"),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
            if (shown.locations.isNotEmpty()) {
                SectionHeader("Places")
                Group(shown.locations) { location, position ->
                    ListRow(
                        location.name,
                        Modifier.testTag("directory-location-${location.name}"),
                        position = position,
                        subtitle = location.path,
                        glyph = Glyph.FOLDER,
                        onClick = { path = location.path },
                    )
                }
            }
            SectionHeader(
                shown.name.ifEmpty { "Directories" },
                trailing = {
                    DButton(
                        if (hidden) "Hide hidden" else "Show hidden",
                        { hidden = !hidden },
                        kind = ButtonKind.PLAIN,
                    )
                },
            )
            val entries = shown.entries.filter { hidden || !it.hidden }
            val rows = entries
            if (shown.parent.isNotEmpty())
                ListRow(
                    "Enclosing directory",
                    Modifier.testTag("directory-parent"),
                    position = if (rows.isEmpty()) Position.SINGLE else Position.FIRST,
                    subtitle = shown.parent,
                    glyph = Glyph.BACK,
                    onClick = { path = shown.parent },
                )
            rows.forEachIndexed { index, entry ->
                val position =
                    if (shown.parent.isNotEmpty())
                        if (index == rows.lastIndex) Position.LAST else Position.MIDDLE
                    else Position.of(index, rows.size)
                ListRow(
                    entry.name,
                    Modifier.testTag("directory-entry-${entry.name}"),
                    position = position,
                    subtitle = if (entry.git_repository) "Git repository" else null,
                    glyph = Glyph.FOLDER,
                    accessory = Accessory.CHEVRON,
                    onClick = { path = entry.path },
                )
            }
            if (entries.isEmpty() && shown.parent.isEmpty()) SectionFooter("No directories here.")
            if (shown.git_repository)
                SectionFooter(
                    "This is a Git working tree. Registered checkouts cannot be synced folders."
                )
        }
    }
}
