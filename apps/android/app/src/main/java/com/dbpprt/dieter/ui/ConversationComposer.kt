@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Card as BoardCard
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.UiMessage
import kotlinx.coroutines.delay
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.Locale
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterAbyss

@Composable
internal fun CommentsBody(state: DieterUiState, model: DieterViewModel, modifier: Modifier = Modifier) {
    val comments = state.conversation?.detail?.commentsList.orEmpty()
    var text by remember { mutableStateOf("") }
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(comments.isNotEmpty()) {
        if (comments.isEmpty()) return@LaunchedEffect
        while (true) {
            delay(60_000)
            now = Instant.now()
        }
    }
    Column(modifier) {
        if (comments.isEmpty()) {
            EmptyList("No comments yet", "Comments are human notes and never wake the agent.", Icons.Outlined.ChatBubbleOutline, Modifier.weight(1f))
        } else {
            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(comments, key = { it.id }) { comment ->
                    Card(
                        colors = CardDefaults.cardColors(containerColor = DieterSurfaceHigh),
                        shape = RoundedCornerShape(16.dp),
                    ) {
                        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 13.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Surface(shape = RoundedCornerShape(7.dp), color = DieterShellTint) {
                                    Text(
                                        if (state.selectedCard?.scope == "board") "BOARD COMMENT" else "CHAT NOTE",
                                        color = DieterShell,
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Bold,
                                        letterSpacing = 0.7.sp,
                                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 4.dp),
                                    )
                                }
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    comment.author.name.ifBlank { "Human" },
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(shortTimestamp(comment.createdAt, now), color = DieterMuted, fontSize = 11.sp)
                            }
                            Spacer(Modifier.height(8.dp))
                            Text(comment.body, color = MaterialTheme.colorScheme.onSurface, fontSize = 14.sp, lineHeight = 20.sp)
                        }
                    }
                }
            }
        }
        MessageComposer(
            value = text,
            placeholder = "Add a comment…",
            enabled = !state.working,
            onValueChange = { text = it },
            onSend = { _, _, _, _ ->
                val message = text.trim()
                if (message.isNotBlank()) {
                    text = ""
                    model.addComment(message)
                }
            },
        )
    }
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
                "Up to 4 attachments · 5 MB each · 6 MB total",
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
                modifier = Modifier.align(Alignment.TopEnd).padding(4.dp).size(25.dp)
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
                Text(attachmentDetails(part), color = DieterMuted, fontSize = 10.sp, maxLines = 1)
            }
            IconButton(onClick = onRemove, enabled = enabled, modifier = Modifier.size(36.dp)) {
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
    harnesses: List<Harness> = emptyList(),
    card: BoardCard? = null,
    contextUsage: ComposerContextUsage? = null,
    attachments: List<MessagePart> = emptyList(),
    error: String? = null,
    onValueChange: (String) -> Unit,
    onAttach: (() -> Unit)? = null,
    onRemoveAttachment: (Int) -> Unit = {},
    onSend: (String, String, String, Map<String, String>) -> Unit,
) {
    val locked = card?.initialPromptSentAt?.isNotBlank() == true
    var provider by remember(card?.id, harnesses) {
        mutableStateOf(card?.provider?.takeIf { it.isNotBlank() } ?: harnesses.firstOrNull()?.id.orEmpty())
    }
    val selectedHarness = harnesses.firstOrNull { it.id == provider } ?: harnesses.firstOrNull()
    var selectedModel by remember(card?.id, provider, selectedHarness) {
        mutableStateOf(card?.model?.takeIf { it.isNotBlank() } ?: selectedHarness?.defaultModel.orEmpty())
    }
    var effort by remember(card?.id, provider, selectedModel) { mutableStateOf(card?.effort.orEmpty()) }
    var providerOptions by remember(card?.id, provider, selectedHarness, card?.providerOptionsMap) {
        mutableStateOf(
            providerOptionValues(
                selectedHarness,
                card?.providerOptionsMap?.takeIf { card.provider == provider }.orEmpty(),
            ),
        )
    }
    val selectedHarnessModel = selectedHarness?.modelsList?.firstOrNull { it.id == selectedModel }
    val effortOptions = selectedHarness?.effortOptionsFor(selectedModel).orEmpty()
    val displayedEffort = effort.ifBlank { selectedHarnessModel?.defaultEffort.orEmpty() }
    val effortLabel = effortOptions.firstOrNull { it.id == displayedEffort }?.name
        ?: displayedEffort.replaceFirstChar { if (it.isLowerCase()) it.uppercaseChar().toString() else it.toString() }
            .ifBlank { "Default" }
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
        if (harnesses.isNotEmpty() && card != null) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box {
                        ComposerSettingPill(selectedHarness?.name ?: provider.ifBlank { "Agent" }, enabled = !locked) { providerMenu = true }
                        DropdownMenu(providerMenu, { providerMenu = false }) {
                            harnesses.forEach { harness ->
                                DropdownMenuItem(text = { Text(harness.name) }, onClick = {
                                    providerMenu = false
                                    provider = harness.id
                                    selectedModel = harness.defaultModel
                                    effort = ""
                                })
                            }
                        }
                    }
                    Box {
                        ComposerSettingPill(selectedHarnessModel?.name ?: selectedModel.ifBlank { "Default model" }, enabled = !locked) { modelMenu = true }
                        DropdownMenu(modelMenu, { modelMenu = false }) {
                            selectedHarness?.modelsList.orEmpty().forEach { harnessModel ->
                                DropdownMenuItem(text = { Text(harnessModel.name) }, onClick = {
                                    modelMenu = false
                                    selectedModel = harnessModel.id
                                    effort = ""
                                })
                            }
                        }
                    }
                    if (effortOptions.isNotEmpty()) {
                        Box {
                            ComposerSettingPill(effortLabel, enabled = !locked) { effortMenu = true }
                            DropdownMenu(effortMenu, { effortMenu = false }) {
                                DropdownMenuItem(text = { Text("Default") }, onClick = { effortMenu = false; effort = "" })
                                effortOptions.forEach { option ->
                                    DropdownMenuItem(text = { Text(option.name) }, onClick = { effortMenu = false; effort = option.id })
                                }
                            }
                        }
                    }
                    selectedHarness?.optionsList.orEmpty().forEach { option ->
                        ProviderOptionControl(
                            option = option,
                            values = providerOptions,
                            enabled = !locked,
                            onValueChange = { id, next -> providerOptions = providerOptions + (id to next) },
                        )
                    }
                }
                if (contextUsage != null) {
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "${formatTokenCount(contextUsage.used)} · ${contextUsage.percent}%",
                        color = DieterMuted.copy(alpha = 0.78f),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                    )
                }
            }
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
                            Box(Modifier.weight(1f).padding(end = 14.dp, top = 15.dp, bottom = 14.dp)) {
                                if (value.isEmpty()) Text(placeholder, color = DieterMuted.copy(alpha = 0.72f), fontSize = 14.sp)
                                innerTextField()
                            }
                        }
                    },
                )
            }
            val canSend = enabled && (value.isNotBlank() || attachments.isNotEmpty())
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(20.dp))
                    .background(DieterPane)
                    .clickable(enabled = canSend) { onSend(provider, selectedModel, effort, providerOptions) }
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

internal data class ComposerContextUsage(val used: Long, val percent: Int)

internal fun latestContextUsage(messages: List<UiMessage>): ComposerContextUsage? {
    messages.asReversed().forEach { message ->
        val raw = message.metadataJson.toString(StandardCharsets.UTF_8)
        if (raw.isBlank()) return@forEach
        val metadata = runCatching { JSONObject(raw) }.getOrNull() ?: return@forEach
        val usage = metadata.optJSONObject("usage") ?: return@forEach
        val rawUsage = usage.optJSONObject("raw")
        val used = rawUsage?.longOrNull("totalTokens")
            ?: usage.longOrNull("totalTokens")
            ?: ((usage.longOrNull("inputTokens") ?: 0L) + (usage.longOrNull("outputTokens") ?: 0L))
        val available = metadata.longOrNull("contextWindowTokens")
        if (used > 0 && available != null && available > 0) {
            return ComposerContextUsage(used, ((used.toDouble() / available) * 100).toInt().coerceIn(0, 100))
        }
    }
    return null
}

internal fun JSONObject.longOrNull(key: String): Long? =
    if (has(key) && !isNull(key)) optLong(key) else null

internal fun formatTokenCount(tokens: Long): String = when {
    tokens >= 1_000_000 -> String.format(Locale.US, "%.1fM", tokens / 1_000_000.0)
    tokens >= 100_000 -> "${tokens / 1_000}k"
    tokens >= 1_000 -> String.format(Locale.US, "%.1fk", tokens / 1_000.0)
    else -> tokens.toString()
}
