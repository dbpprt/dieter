package com.getdieter.mobile.folders

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.FolderDirection
import com.getdieter.client.v1.FolderNetworkPolicy
import com.getdieter.client.v1.Tone as SliceTone
import com.getdieter.core.folders.FolderSettings
import com.getdieter.mobile.design.*

// Shared pieces of the folder screens: status colors, the folder header and core wording.

/** The color a status line's tone reads in. */
internal val SliceTone.color: Color
    @Composable
    @ReadOnlyComposable
    get() =
        when (this) {
            SliceTone.TONE_SUCCESS -> palette.success
            SliceTone.TONE_WARNING -> palette.warning
            SliceTone.TONE_DANGER -> palette.destructive
            SliceTone.TONE_ACTIVE -> palette.info
            else -> palette.tertiaryLabel
        }

/** A small status dot in a tone's color. */
@Composable
internal fun StatusDot(tone: SliceTone, modifier: Modifier = Modifier) {
    Box(modifier.size(8.dp).clip(CircleShape).background(tone.color))
}

/** A status line with its dot. */
@Composable
internal fun StatusLine(text: String, tone: SliceTone, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        StatusDot(tone)
        Spacer(Modifier.width(6.dp))
        Text(
            text,
            style = type.footnote,
            color = palette.secondaryLabel,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** A raised card at the top of a folder page: a title, detail lines and actions. */
@Composable
internal fun FolderHero(
    title: String,
    modifier: Modifier = Modifier,
    tone: SliceTone = SliceTone.TONE_NEUTRAL,
    lines: List<String> = emptyList(),
    progress: Float? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Column(
        modifier
            .fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(groupShape(Position.SINGLE))
            .background(palette.cell)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(tone)
            Spacer(Modifier.width(8.dp))
            Text(
                title,
                Modifier.testTag("folder-status"),
                style = type.headline.copy(fontWeight = FontWeight.SemiBold),
                color = palette.label,
            )
        }
        progress?.let { ProgressBar(it, Modifier.padding(vertical = 6.dp)) }
        lines
            .filter { it.isNotBlank() }
            .forEach { Text(it, style = type.footnote, color = palette.secondaryLabel) }
        Row(
            Modifier.padding(top = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            content = actions,
        )
    }
}

/** An amber notice above a page's content, e.g. files waiting to upload. */
@Composable
internal fun FolderNote(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier
            .fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(groupShape(Position.SINGLE))
            .background(palette.warning.copy(alpha = .12f))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        style = type.footnote,
        color = palette.label,
    )
}

/** A file's glyph by its name. */
internal fun fileGlyph(name: String, directory: Boolean): Glyph {
    if (directory) return Glyph.FOLDER
    val extension = name.substringAfterLast('.', "").lowercase()
    return when (extension) {
        "png",
        "jpg",
        "jpeg",
        "gif",
        "heic",
        "webp",
        "svg" -> Glyph.IMAGE
        "md",
        "txt",
        "pdf",
        "doc",
        "docx",
        "rtf" -> Glyph.DOC_TEXT
        "kt",
        "swift",
        "go",
        "py",
        "js",
        "ts",
        "json",
        "yaml",
        "yml",
        "sh" -> Glyph.CODE
        else -> Glyph.FILE
    }
}

// The core's wording of the client contract's enums, which share the record's numbers.

internal fun FolderDirection.label(): String = FolderSettings.directionLabel(coreDirection())

internal fun FolderDirection.shortLabel(): String =
    FolderSettings.directionShortLabel(coreDirection())

internal fun FolderDirection.detail(): String = FolderSettings.directionDetail(coreDirection())

private fun FolderDirection.coreDirection() =
    com.getdieter.core.v1.FolderDirection.fromValue(value)
        ?: com.getdieter.core.v1.FolderDirection.FOLDER_DIRECTION_TWO_WAY

internal val folderDirections: List<FolderDirection> =
    FolderSettings.DIRECTION_OPTIONS.mapNotNull { FolderDirection.fromValue(it.value) }

internal fun FolderNetworkPolicy.label(): String = FolderSettings.networkLabel(corePolicy())

internal fun FolderNetworkPolicy.shortLabel(): String =
    FolderSettings.networkShortLabel(corePolicy())

private fun FolderNetworkPolicy.corePolicy() =
    com.getdieter.core.v1.FolderNetworkPolicy.fromValue(value)
        ?: com.getdieter.core.v1.FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED

internal val folderNetworks: List<FolderNetworkPolicy> =
    FolderSettings.NETWORK_OPTIONS.mapNotNull { FolderNetworkPolicy.fromValue(it.value) }
