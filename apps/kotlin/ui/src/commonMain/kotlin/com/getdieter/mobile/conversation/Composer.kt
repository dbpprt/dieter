@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.MessagePart
import com.getdieter.client.v1.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*

@Composable
internal fun Composer(
    store: MobileStore,
    view: ConversationSlice,
    selected: String,
    draft: String,
    onDraft: (String) -> Unit,
    attachments: List<MessagePart>,
    onRemoveAttachment: (Int) -> Unit,
    onAttach: () -> Unit,
    busy: Boolean,
    sending: Boolean,
    bottomInset: androidx.compose.ui.unit.Dp,
    onAgent: () -> Unit,
    onSend: () -> Unit,
) {
    val state = view.state
    val agent = state?.agent
    val canSend =
        (draft.isNotBlank() || attachments.isNotEmpty()) && !busy && !sending && view.card != null
    val showStop = state?.can_halt == true && draft.isBlank() && attachments.isEmpty()
    val reviewable =
        view.card?.scope != "chat" &&
            view.card != null &&
            state?.can_halt != true &&
            view.board?.lanes?.any { it.id == "review" } == true &&
            view.card?.lane != "review"
    val imeVisible =
        (WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0)
    Column(
        Modifier.fillMaxWidth()
            .background(
                if (apple)
                    Brush.verticalGradient(
                        0f to palette.background.copy(alpha = 0f),
                        .18f to palette.background,
                    )
                else SolidColor(colors.surfaceContainer)
            )
            .padding(
                top = if (apple) 10.dp else 8.dp,
                bottom = if (imeVisible) 8.dp else bottomInset.coerceAtLeast(8.dp),
            )
    ) {
        Row(
            Modifier.fillMaxWidth()
                .testTag("composer-chips")
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = ScreenMargin, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (agent != null)
                ComposerChip(
                    listOf(agent.provider_label, agent.model_label, agent.effort_label)
                        .filter { it.isNotEmpty() }
                        .joinToString(" · "),
                    Glyph.SPARKLES,
                    Modifier.testTag("agent-chip"),
                    onClick = onAgent,
                    chevron = true,
                )
            if ((state?.context_percent ?: 0) > 0)
                ComposerChip(
                    "${state?.context_percent}% context",
                    Glyph.CPU,
                    warning = state?.context_near_limit == true,
                )
            if (state?.can_start == true)
                ComposerChip(
                    "Start",
                    Glyph.PLAY,
                    onClick = store.conversation::start,
                    prominent = true,
                )
            if (reviewable)
                ComposerChip(
                    "Move to Review",
                    Glyph.CHECKLIST,
                    Modifier.testTag("move-review"),
                    onClick = { store.conversation.move("review") },
                )
            state
                ?.pending_tools_summary
                ?.takeIf { it.isNotEmpty() }
                ?.let { ComposerChip(it, Glyph.HOURGLASS) }
        }
        if (attachments.isNotEmpty())
            Row(
                Modifier.fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = ScreenMargin, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                attachments.forEachIndexed { index, part ->
                    Row(
                        Modifier.clip(CircleShape)
                            .background(palette.fill)
                            .padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Glyph.ATTACH, null, tint = palette.secondaryLabel, size = 14.dp)
                        Spacer(Modifier.width(5.dp))
                        Text(
                            part.filename.ifEmpty { "Attachment" },
                            style = type.footnote,
                            color = palette.label,
                            maxLines = 1,
                        )
                        Box(
                            Modifier.size(28.dp)
                                .clip(CircleShape)
                                .pressable(onClick = { onRemoveAttachment(index) })
                                .semantics { contentDescription = "Remove attachment" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Glyph.CLOSE,
                                null,
                                tint = palette.secondaryLabel,
                                size = 12.dp,
                                weight = GlyphWeight.BOLD,
                            )
                        }
                    }
                }
            }
        Row(
            Modifier.fillMaxWidth()
                .padding(start = ScreenMargin - 4.dp, end = ScreenMargin - 4.dp, top = 6.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircleButton(
                Glyph.ADD,
                "Attach images or files",
                onAttach,
                Modifier.testTag("attach"),
                enabled = attachments.size < 4,
                size = if (apple) 38.dp else 44.dp,
            )
            Row(
                Modifier.weight(1f)
                    .heightIn(min = if (apple) 38.dp else 48.dp)
                    .clip(RoundedCornerShape(if (apple) 20.dp else 24.dp))
                    .background(if (apple) palette.cell else colors.surfaceContainerHighest)
                    .then(
                        if (apple)
                            Modifier.border(
                                .5.dp,
                                palette.separator.copy(alpha = .6f),
                                RoundedCornerShape(20.dp),
                            )
                        else Modifier
                    )
                    .padding(start = 14.dp, end = 4.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Box(Modifier.weight(1f).padding(vertical = if (apple) 8.dp else 12.dp)) {
                    if (draft.isEmpty())
                        Text(
                            if (view.state?.working == true) "Queue a message…" else "Message",
                            style = type.body,
                            color = palette.secondaryLabel,
                        )
                    BasicTextField(
                        draft,
                        onDraft,
                        Modifier.fillMaxWidth().testTag("message-input").semantics {
                            contentDescription = "Message"
                        },
                        textStyle = type.body.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                        maxLines = 6,
                    )
                }
                val sendSize = if (apple) 30.dp else 40.dp
                Box(Modifier.padding(bottom = if (apple) 4.dp else 4.dp)) {
                    if (showStop)
                        SendButton(
                            Glyph.STOP,
                            "Stop agent",
                            store.conversation::stop,
                            enabled = !busy,
                            size = sendSize,
                            destructive = true,
                        )
                    else
                        SendButton(
                            Glyph.ARROW_UP,
                            if (sending) "Sending message" else "Send message",
                            onSend,
                            enabled = canSend,
                            size = sendSize,
                            loading = sending,
                        )
                }
            }
        }
    }
}

@Composable
internal fun SendButton(
    glyph: Glyph,
    description: String,
    onClick: () -> Unit,
    enabled: Boolean,
    size: androidx.compose.ui.unit.Dp,
    destructive: Boolean = false,
    loading: Boolean = false,
    tag: String = if (glyph == Glyph.STOP) "stop-agent" else "send-message",
) {
    val container =
        when {
            !enabled -> palette.fill
            destructive && !apple -> colors.errorContainer
            apple -> palette.accent.let { if (it == palette.label) palette.label else it }
            else -> colors.primary
        }
    val content =
        when {
            !enabled -> palette.tertiaryLabel
            destructive && !apple -> colors.onErrorContainer
            apple -> palette.onAccent
            else -> colors.onPrimary
        }
    Box(
        Modifier.size(size.coerceAtLeast(44.dp))
            .clip(CircleShape)
            .pressable(onClick = onClick, enabled = enabled && !loading, scaleOnPress = true)
            .semantics { contentDescription = description }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(size).background(container, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (loading) Spinner(Modifier.size(size * .55f), color = content)
            else
                Icon(
                    glyph,
                    null,
                    tint = content,
                    size = size * (if (glyph == Glyph.STOP) .42f else .55f),
                    weight = GlyphWeight.BOLD,
                )
        }
    }
}

@Composable
internal fun ComposerChip(
    text: String,
    glyph: Glyph,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    chevron: Boolean = false,
    warning: Boolean = false,
    prominent: Boolean = false,
) {
    val tint =
        if (warning) palette.warning.readableOn(palette.background)
        else if (prominent) palette.onAccent else palette.label
    Row(
        modifier
            .height(30.dp)
            .clip(CircleShape)
            .background(
                if (prominent) palette.accent
                else if (apple) palette.cell else colors.surfaceContainerHigh
            )
            .then(
                if (apple && !prominent)
                    Modifier.border(.5.dp, palette.separator.copy(alpha = .5f), CircleShape)
                else Modifier
            )
            .then(if (onClick != null) Modifier.pressable(onClick = onClick) else Modifier)
            .padding(horizontal = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(glyph, null, tint = tint, size = 13.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = tint,
            maxLines = 1,
        )
        if (chevron)
            Icon(
                Glyph.CHEVRON_DOWN,
                null,
                tint = palette.secondaryLabel,
                size = 10.dp,
                weight = GlyphWeight.BOLD,
            )
    }
}
