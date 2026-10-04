@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.ConversationDraft
import com.dbpprt.dieter.core.presentation.ContextUsage
import com.dbpprt.dieter.core.presentation.ConversationPresentation
import com.dbpprt.dieter.core.presentation.TokenCounts
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.ui.theme.DieterAbyss
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh

/**
 * The open conversation composer's agent pickers: the composer's choice
 * while it differs from the card's agent, else the card's agent, against
 * the conversation machine's [catalog]. Null until the card and the catalog
 * are known.
 */
internal fun composerAgent(state: DieterUiState, presentation: ConversationPresentation, catalog: HarnessCatalog?): AgentControls? {
    val card = presentation.card ?: return null
    val harnesses = catalog?.harnesses.orEmpty()
    if (harnesses.isEmpty()) return null
    return AgentControls.forComposer(state.composerDraft.selection, card, harnesses, hasMessages = presentation.loadedMessages > 0)
        .copy(enabled = !state.working)
}

@Composable
internal fun AttachmentPickerSheet(
    onDismiss: () -> Unit,
    onImages: () -> Unit,
    onFiles: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = DieterSurfaceHigh) {
        Column(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add attachment", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                "Choose images or browse any document on this device.",
                color = DieterMuted,
                fontSize = 12.sp,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                AttachmentSourceCard(
                    title = "Images",
                    detail = "Photo library",
                    icon = Icons.Outlined.PhotoLibrary,
                    modifier = Modifier.weight(1f).testTag("attach-images"),
                    onClick = onImages,
                )
                AttachmentSourceCard(
                    title = "Files",
                    detail = "Browse device",
                    icon = Icons.Outlined.Description,
                    modifier = Modifier.weight(1f).testTag("attach-files"),
                    onClick = onFiles,
                )
            }
            Text(
                Attachments.LIMITS,
                color = DieterMuted.copy(alpha = 0.78f),
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
internal fun AttachmentSourceCard(
    title: String,
    detail: String,
    icon: ImageVector,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        color = DieterSurface,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(
                Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = DieterShell, modifier = Modifier.size(21.dp))
            }
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(detail, color = DieterMuted, fontSize = 11.sp)
            }
        }
    }
}

@Composable
internal fun ComposerAttachmentPreview(
    part: MessagePart,
    index: Int,
    enabled: Boolean,
    onRemove: () -> Unit,
) {
    val bitmap = rememberAttachmentBitmap(part, maxDimension = 360)
    if (bitmap != null) {
        Box(
            Modifier.width(116.dp).height(88.dp).clip(RoundedCornerShape(12.dp))
                .background(DieterSurfaceHigh)
                .testTag("composer-attachment-$index"),
        ) {
            Image(
                bitmap = bitmap,
                contentDescription = part.filename.ifBlank { "Attached image" },
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            Text(
                part.filename.ifBlank { "Image" },
                color = Color.White,
                fontSize = 10.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.58f)).padding(horizontal = 7.dp, vertical = 5.dp),
            )
            IconButton(
                onClick = onRemove,
                enabled = enabled,
                modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(48.dp)
                    .clip(CircleShape).background(Color.Black.copy(alpha = 0.62f)),
            ) {
                Icon(Icons.Outlined.Close, "Remove ${part.filename.ifBlank { "image" }}", tint = Color.White, modifier = Modifier.size(14.dp))
            }
        }
        return
    }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = DieterSurfaceHigh,
        border = androidx.compose.foundation.BorderStroke(1.dp, DieterOutline),
        modifier = Modifier.width(224.dp).height(64.dp).testTag("composer-attachment-$index"),
    ) {
        Row(
            Modifier.padding(start = 10.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(DieterShellTint),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Description, null, tint = DieterShell, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(9.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    part.filename.ifBlank { "Attachment" },
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(Attachments.details(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
            }
            IconButton(onClick = onRemove, enabled = enabled, modifier = Modifier.size(48.dp)) {
                Icon(Icons.Outlined.Close, "Remove ${part.filename.ifBlank { "attachment" }}", Modifier.size(16.dp))
            }
        }
    }
}

@Composable
internal fun MessageComposer(
    value: String,
    placeholder: String,
    enabled: Boolean,
    /** The agent pickers; null hides them (no catalog yet, or no conversation). */
    controls: AgentControls? = null,
    contextUsage: ContextUsage? = null,
    respondingModel: String? = null,
    attachments: List<MessagePart> = emptyList(),
    error: String? = null,
    onValueChange: (String) -> Unit,
    /** A picker choice: the next selection, computed from the core's current pickers. */
    onChoose: ((AgentControls) -> HarnessSelection) -> Unit = {},
    onAttach: (() -> Unit)? = null,
    onRemoveAttachment: (Int) -> Unit = {},
    onSend: () -> Unit,
) {
    val tablet = LocalTabletWorkspace.current
    var settingsExpanded by remember { mutableStateOf(false) }
    var providerMenu by remember { mutableStateOf(false) }
    var modelMenu by remember { mutableStateOf(false) }
    var effortMenu by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (attachments.isNotEmpty()) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                attachments.forEachIndexed { index, part ->
                    ComposerAttachmentPreview(
                        part = part,
                        index = index,
                        enabled = enabled,
                        onRemove = { onRemoveAttachment(index) },
                    )
                }
            }
        }
        if (error != null) Text(error, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
        if (controls != null && (!tablet || settingsExpanded)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        ComposerSettingPill(controls.providerLabel, enabled = controls.providerEnabled) { providerMenu = true }
                        DropdownMenu(providerMenu, { providerMenu = false }) {
                            controls.harnesses.forEach { harness ->
                                DropdownMenuItem(text = { Text(harness.name) }, enabled = controls.providerEnabled, onClick = {
                                    providerMenu = false
                                    onChoose { it.choosingProvider(harness) }
                                })
                            }
                        }
                    }
                    Box {
                        ComposerSettingPill(controls.modelLabel, enabled = controls.modelEnabled) { modelMenu = true }
                        DropdownMenu(modelMenu, { modelMenu = false }) {
                            controls.harness?.models.orEmpty().forEach { harnessModel ->
                                DropdownMenuItem(text = { Text(harnessModel.name) }, enabled = controls.modelEnabled, onClick = {
                                    modelMenu = false
                                    onChoose { it.choosingModel(harnessModel.id) }
                                })
                            }
                        }
                    }
                    if (controls.efforts.isNotEmpty()) {
                        Box {
                            ComposerSettingPill(controls.effortLabel, enabled = controls.effortEnabled) { effortMenu = true }
                            DropdownMenu(effortMenu, { effortMenu = false }) {
                                controls.effortChoices.forEach { option ->
                                    DropdownMenuItem(text = { Text(option.name) }, enabled = controls.effortEnabled, onClick = {
                                        effortMenu = false
                                        onChoose { it.choosingEffort(option.id) }
                                    })
                                }
                            }
                        }
                    }
                    controls.options.forEach { option ->
                        ProviderOptionControl(
                            option = option,
                            value = controls.optionValue(option),
                            enabled = controls.optionEnabled(option),
                            onValueChange = { id, next -> onChoose { it.settingOption(id, next) } },
                        )
                    }
                }
                if (contextUsage != null) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${TokenCounts.compact(contextUsage.usedTokens)} · ${contextUsage.percent}%",
                        color = DieterMuted.copy(alpha = 0.78f),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                }
            }
            if (controls.locked) {
                Text(
                    "Settings apply to your next message. The current turn keeps its settings.",
                    color = DieterMuted,
                    fontSize = 11.sp,
                    modifier = Modifier.testTag("composer-next-message-settings"),
                )
            }
        }
        if (respondingModel != null) {
            Text(
                "Last Claude response model: $respondingModel",
                color = DieterMuted,
                fontSize = 11.sp,
                modifier = Modifier.fillMaxWidth().testTag("last-claude-response-model"),
            )
        }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Surface(
                color = DieterSurfaceHigh,
                shape = RoundedCornerShape(27.dp),
                modifier = Modifier.weight(1f),
            ) {
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    enabled = enabled,
                    maxLines = 5,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(
                        color = MaterialTheme.colorScheme.onSurface,
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                    ),
                    cursorBrush = SolidColor(DieterShell),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 54.dp, max = 144.dp).testTag("message-input"),
                    decorationBox = { innerTextField ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 54.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            if (onAttach != null) {
                                IconButton(onClick = onAttach, enabled = enabled, modifier = Modifier.size(42.dp)) {
                                    Icon(Icons.Outlined.AttachFile, "Attach images or files", tint = DieterMuted, modifier = Modifier.size(19.dp))
                                }
                            } else {
                                Spacer(Modifier.width(17.dp))
                            }
                            if (tablet && controls != null) {
                                IconButton(
                                    onClick = { settingsExpanded = !settingsExpanded },
                                    modifier = Modifier.size(48.dp).testTag("composer-agent-settings"),
                                ) {
                                    Icon(Icons.Outlined.Tune, if (settingsExpanded) "Hide agent settings" else "Show agent settings", tint = DieterMuted, modifier = Modifier.size(19.dp))
                                }
                            }
                            Box(Modifier.weight(1f).padding(end = 14.dp, top = 15.dp, bottom = 14.dp)) {
                                if (value.isEmpty()) Text(placeholder, color = DieterMuted.copy(alpha = 0.72f), fontSize = 14.sp)
                                innerTextField()
                            }
                        }
                    },
                )
            }
            val canSend = enabled && ConversationDraft(value, attachments).hasContent
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(20.dp))
                    .background(DieterPane)
                    .clickable(enabled = canSend, onClick = onSend)
                    .testTag("send-message"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    "Send",
                    tint = if (canSend) DieterAbyss else DieterAbyss.copy(alpha = 0.55f),
                    modifier = Modifier.size(23.dp),
                )
            }
        }
    }
}

@Composable
internal fun ComposerSettingPill(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.height(32.dp).widthIn(max = 142.dp)
            .clip(RoundedCornerShape(9.dp))
            .background(DieterSurfaceHigh)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = DieterMuted, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
