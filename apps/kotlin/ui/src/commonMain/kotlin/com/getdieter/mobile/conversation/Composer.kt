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
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
    style: ComposerStyle = ComposerStyle.CLASSIC,
    backdrop: GlassBackdrop? = null,
) {
    if (style != ComposerStyle.CLASSIC) {
        FloatingComposer(
            store,
            view,
            draft,
            onDraft,
            attachments,
            onRemoveAttachment,
            onAttach,
            busy,
            sending,
            bottomInset,
            onAgent,
            onSend,
            glass = style == ComposerStyle.GLASS,
            backdrop = backdrop,
        )
        return
    }
    val state = view.state
    val agent = state?.agent
    // An account that cannot run on the conversation's machine blocks sending; the timeline's
    // provider notice offers to sign it in or choose another.
    val canSend =
        (draft.isNotBlank() || attachments.isNotEmpty()) &&
            !busy &&
            !sending &&
            view.card != null &&
            agent?.account_blocked != true
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
                    // Agents with provider accounts name the account in place of the effort.
                    (if (agent.accounts.isNotEmpty())
                            listOf(agent.provider_label, agent.account_label, agent.model_label)
                        else listOf(agent.provider_label, agent.model_label, agent.effort_label))
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

/** What the composer offers besides typing, shared by every composer style. */
private class ComposerState(
    view: ConversationSlice,
    draft: String,
    attachments: Int,
    busy: Boolean,
    sending: Boolean,
) {
    val state = view.state
    val agent = state?.agent
    // An account that cannot run on the conversation's machine blocks sending; the timeline's
    // provider notice offers to sign it in or choose another.
    val canSend =
        (draft.isNotBlank() || attachments > 0) &&
            !busy &&
            !sending &&
            view.card != null &&
            agent?.account_blocked != true
    val showStop = state?.can_halt == true && draft.isBlank() && attachments == 0
    val reviewable =
        view.card?.scope != "chat" &&
            view.card != null &&
            state?.can_halt != true &&
            view.board?.lanes?.any { it.id == "review" } == true &&
            view.card?.lane != "review"
    /** Without the provider, for a narrow composer: "Opus · Extra high". */
    val shortAgentLabel = agent?.let {
        (if (it.accounts.isNotEmpty()) listOf(it.account_label, it.model_label)
            else listOf(it.model_label, it.effort_label))
            .filter { label -> label.isNotEmpty() }
            .joinToString(" · ")
            .ifEmpty { it.provider_label }
    }
    val agentLabel = agent?.let {
        // Agents with provider accounts name the account in place of the effort.
        (if (it.accounts.isNotEmpty()) listOf(it.provider_label, it.account_label, it.model_label)
            else listOf(it.provider_label, it.model_label, it.effort_label))
            .filter { label -> label.isNotEmpty() }
            .joinToString(" · ")
    }
    val pendingTools = state?.pending_tools_summary.orEmpty()
    val hasActions = state?.can_start == true || reviewable || pendingTools.isNotEmpty()
}

/**
 * The composer as a card floating above the transcript, which scrolls on beneath it. The message
 * field fills the card; its controls sit inside along the bottom edge: attach, the agent, the
 * context in use, and send. Commands about the conversation (Start, Move to Review, waiting tools)
 * float above the card as chips. A raised card ([glass] false) separates itself with a lit surface,
 * an outline and a shadow; the glass card shows the transcript bent and blurred through it. Focus
 * draws the outline in the accent.
 */
@Composable
private fun FloatingComposer(
    store: MobileStore,
    view: ConversationSlice,
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
    glass: Boolean,
    backdrop: GlassBackdrop?,
) {
    val model = ComposerState(view, draft, attachments.size, busy, sending)
    val state = model.state
    val imeVisible =
        (WindowInsets.ime.getBottom(androidx.compose.ui.platform.LocalDensity.current) > 0)
    var focused by remember { mutableStateOf(false) }
    val dark = palette.dark
    val shape = RoundedCornerShape(26.dp)
    val outline by
        androidx.compose.animation.animateColorAsState(
            when {
                focused -> colors.primary.copy(alpha = if (dark) .8f else .55f)
                glass -> Color.Transparent
                dark -> Color.White.copy(alpha = .1f)
                else -> colors.outlineVariant.copy(alpha = .85f)
            },
            label = "composer-outline",
        )
    val card =
        if (glass) Modifier.glass(backdrop, shape, GlassStyles.panel())
        else
            Modifier.dropShadow(
                    shape,
                    androidx.compose.ui.graphics.shadow.Shadow(
                        radius = 20.dp,
                        color = Color.Black.copy(alpha = if (dark) .55f else .11f),
                        offset = androidx.compose.ui.unit.DpOffset(0.dp, 6.dp),
                    ),
                )
                .background(
                    if (dark) colors.surfaceContainerHigh else colors.surfaceContainerLowest,
                    shape,
                )
    Column(
        Modifier.fillMaxWidth()
            .padding(bottom = if (imeVisible) 8.dp else bottomInset.coerceAtLeast(8.dp) + 2.dp)
    ) {
        if (model.hasActions)
            Row(
                Modifier.fillMaxWidth()
                    .testTag("composer-chips")
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (state?.can_start == true)
                    FloatingChip(
                        "Start",
                        Glyph.PLAY,
                        backdrop,
                        glass,
                        onClick = store.conversation::start,
                        prominent = true,
                    )
                if (model.reviewable)
                    FloatingChip(
                        "Move to Review",
                        Glyph.CHECKLIST,
                        backdrop,
                        glass,
                        Modifier.testTag("move-review"),
                        onClick = { store.conversation.move("review") },
                    )
                if (model.pendingTools.isNotEmpty())
                    FloatingChip(model.pendingTools, Glyph.HOURGLASS, backdrop, glass)
            }
        Column(
            Modifier.padding(horizontal = 10.dp)
                .fillMaxWidth()
                .then(card)
                .border(if (focused) 1.5.dp else 1.dp, outline, shape)
                .testTag("composer-card")
        ) {
            if (attachments.isNotEmpty())
                Row(
                    Modifier.fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(start = 10.dp, end = 10.dp, top = 10.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    attachments.forEachIndexed { index, part ->
                        AttachmentPill(part) { onRemoveAttachment(index) }
                    }
                }
            Box(
                Modifier.fillMaxWidth()
                    .padding(start = 18.dp, end = 16.dp, top = 15.dp, bottom = 4.dp)
            ) {
                if (draft.isEmpty())
                    Text(
                        if (state?.working == true) "Queue a message…" else "Message",
                        style = type.body,
                        color = palette.secondaryLabel,
                    )
                BasicTextField(
                    draft,
                    onDraft,
                    Modifier.fillMaxWidth()
                        .onFocusChanged { focused = it.isFocused }
                        .testTag("message-input")
                        .semantics { contentDescription = "Message" },
                    textStyle = type.body.copy(color = palette.label),
                    cursorBrush = SolidColor(colors.primary),
                    maxLines = 8,
                )
            }
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                // A narrow card names the model alone and keeps the context to its ring.
                val roomy = maxWidth >= 420.dp
                Row(
                    Modifier.fillMaxWidth().padding(start = 6.dp, end = 6.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    ToolbarButton(
                        Glyph.ADD,
                        "Attach images or files",
                        onAttach,
                        Modifier.testTag("attach"),
                        enabled = attachments.size < 4,
                    )
                    (if (roomy) model.agentLabel else model.shortAgentLabel)?.let { label ->
                        ToolbarChip(
                            label,
                            Glyph.SPARKLES,
                            Modifier.weight(1f, fill = false).testTag("agent-chip"),
                            onClick = onAgent,
                            chevron = true,
                        )
                    }
                    val context = state?.context_percent ?: 0
                    if (context > 0)
                        ContextGauge(context, state?.context_near_limit == true, showNumber = roomy)
                    Spacer(Modifier.weight(.001f))
                    if (model.showStop)
                        SendButton(
                            Glyph.STOP,
                            "Stop agent",
                            store.conversation::stop,
                            enabled = !busy,
                            size = 40.dp,
                            destructive = true,
                        )
                    else
                        SendButton(
                            Glyph.ARROW_UP,
                            if (sending) "Sending message" else "Send message",
                            onSend,
                            enabled = model.canSend,
                            size = 40.dp,
                            loading = sending,
                        )
                }
            }
        }
    }
}

@Composable
private fun AttachmentPill(part: MessagePart, onRemove: () -> Unit) {
    Row(
        Modifier.clip(CircleShape)
            .background(colors.surfaceContainerHigh)
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
            Modifier.size(28.dp).clip(CircleShape).pressable(onClick = onRemove).semantics {
                contentDescription = "Remove attachment"
            },
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

/** A round control inside the composer card, e.g. attach. */
@Composable
private fun ToolbarButton(
    glyph: Glyph,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Box(
        modifier
            .size(44.dp)
            .clip(CircleShape)
            .pressable(onClick = onClick, enabled = enabled)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.size(36.dp)
                .background(
                    if (palette.dark) colors.surfaceContainerHighest
                    else colors.surfaceContainerHigh,
                    CircleShape,
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                glyph,
                null,
                tint = if (enabled) palette.label else palette.tertiaryLabel,
                size = 20.dp,
                weight = GlyphWeight.MEDIUM,
            )
        }
    }
}

/** The agent picker inside the composer card. */
@Composable
private fun ToolbarChip(
    text: String,
    glyph: Glyph,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    chevron: Boolean = false,
) {
    Row(
        modifier
            .height(36.dp)
            .clip(CircleShape)
            .background(
                if (palette.dark) colors.surfaceContainerHighest else colors.surfaceContainerHigh
            )
            .pressable(onClick = onClick)
            .padding(start = 11.dp, end = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(glyph, null, tint = palette.accent, size = 15.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            Modifier.weight(1f, fill = false),
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = palette.label,
            maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
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

/** The share of the model's context in use, as a ring and a number. */
@Composable
private fun ContextGauge(percent: Int, nearLimit: Boolean, showNumber: Boolean = true) {
    val tint =
        if (nearLimit) palette.warning.readableOn(palette.background) else palette.secondaryLabel
    val track = palette.separator
    Row(
        Modifier.height(36.dp).padding(horizontal = 6.dp).semantics(mergeDescendants = true) {
            contentDescription = "$percent% context used"
        },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        androidx.compose.foundation.Canvas(Modifier.size(15.dp)) {
            val stroke = 2.4.dp.toPx()
            val inset = stroke / 2
            val arc = androidx.compose.ui.geometry.Size(size.width - stroke, size.height - stroke)
            val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
            drawArc(
                track,
                0f,
                360f,
                false,
                topLeft,
                arc,
                style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
            )
            drawArc(
                tint,
                -90f,
                360f * percent.coerceIn(0, 100) / 100f,
                false,
                topLeft,
                arc,
                style =
                    androidx.compose.ui.graphics.drawscope.Stroke(
                        stroke,
                        cap = androidx.compose.ui.graphics.StrokeCap.Round,
                    ),
            )
        }
        if (showNumber)
            Text(
                "$percent%",
                style = type.footnote.copy(fontWeight = FontWeight.Medium),
                color = tint,
            )
    }
}

/** A command chip floating above the composer card, over the transcript. */
@Composable
private fun FloatingChip(
    text: String,
    glyph: Glyph,
    backdrop: GlassBackdrop?,
    glass: Boolean,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    prominent: Boolean = false,
) {
    val tint = if (prominent) palette.onAccent else palette.label
    val surface =
        when {
            prominent -> Modifier.glass(backdrop, CircleShape, GlassStyles.tinted(palette.accent))
            glass -> Modifier.glass(backdrop, CircleShape, GlassStyles.panel())
            else ->
                Modifier.dropShadow(
                        CircleShape,
                        androidx.compose.ui.graphics.shadow.Shadow(
                            radius = 10.dp,
                            color = Color.Black.copy(alpha = if (palette.dark) .5f else .1f),
                            offset = androidx.compose.ui.unit.DpOffset(0.dp, 3.dp),
                        ),
                    )
                    .background(
                        if (palette.dark) colors.surfaceContainerHigh
                        else colors.surfaceContainerLowest,
                        CircleShape,
                    )
                    .border(
                        1.dp,
                        if (palette.dark) Color.White.copy(alpha = .1f)
                        else colors.outlineVariant.copy(alpha = .85f),
                        CircleShape,
                    )
        }
    Row(
        modifier
            .height(34.dp)
            .then(surface)
            .clip(CircleShape)
            .then(if (onClick != null) Modifier.pressable(onClick = onClick) else Modifier)
            .padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(glyph, null, tint = tint, size = 14.dp, weight = GlyphWeight.MEDIUM)
        Text(
            text,
            style = type.footnote.copy(fontWeight = FontWeight.Medium),
            color = tint,
            maxLines = 1,
        )
    }
}
