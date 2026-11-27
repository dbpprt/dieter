package com.getdieter.mobile.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.getdieter.core.reviews.ReviewerForm
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.AgentSettings
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.store.*

/**
 * Settings › Code reviewer: the account's one reviewer setting, which every machine uses when a
 * conversation's agent asks for a review or the user starts one. The core words and checks it; the
 * pickers show the edited machine's catalog.
 */
@Composable
internal fun CodeReviewerScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val settings by store.codeReview.settings.collectAsState()
    val metadata by store.codeReview.metadata.collectAsState()
    val daemonId by store.codeReview.daemonId.collectAsState()
    val problem by store.codeReview.problem.collectAsState()
    val saving by store.codeReview.saving.collectAsState()
    val available = ReviewerForm.machine(session.machines)
    DisposableEffect(store) { onDispose(store.codeReview.show(session.machines)) }
    // A machine that comes online after the screen opened is read then.
    LaunchedEffect(available) {
        if (available != null && available != store.codeReview.daemonId.value)
            store.codeReview.load(session.machines)
    }
    val harnesses = ReviewerForm.harnesses(metadata, daemonId)
    var draft by remember(settings) { mutableStateOf(settings) }
    val current = draft
    Screen(
        ScreenChrome(
            "Code reviewer",
            subtitle = settings?.let { ReviewerForm.status(it, harnesses) }.orEmpty(),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().imePadding().testTag("code-reviewer-settings"),
            state = listState,
            contentPadding = padding,
        ) {
            item("intro") {
                Spacer(Modifier.height(8.dp))
                SectionFooter(
                    "When a conversation has code review on, its agent can ask this reviewer to " +
                        "check its changes. One setting for all your machines."
                )
            }
            if (problem.isNotEmpty())
                item("problem") {
                    Banner(
                        "Code reviewer",
                        problem,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Retry",
                        onAction = { store.codeReview.load(session.machines) },
                    )
                }
            if (current == null) {
                if (problem.isEmpty())
                    item("loading") {
                        Box(
                            Modifier.fillMaxWidth().padding(40.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Spinner(Modifier.size(24.dp))
                        }
                    }
                return@LazyColumn
            }
            item("agent") {
                SectionHeader("Reviewer")
                AgentSettings(
                    if (harnesses.isEmpty()) null else ReviewerForm.agent(current, harnesses)
                ) { choice ->
                    draft = ReviewerForm.choosing(current, harnesses, choice)
                }
                if (!current.configured) SectionFooter(ReviewerForm.DEFAULTS)
            }
            item("depth") {
                SectionHeader("Depth")
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    val depths = ReviewerForm.DEPTHS
                    Segmented(
                        depths.map(ReviewerForm::depthTitle),
                        depths.indexOf(current.depth).coerceAtLeast(0),
                        { draft = current.copy(depth = depths[it]) },
                        testTagPrefix = "code-reviewer-depth",
                    )
                    Text(
                        ReviewerForm.depthDetail(current.depth.ifEmpty { ReviewerForm.QUICK }),
                        style = type.footnote,
                        color = palette.secondaryLabel,
                    )
                }
            }
            item("limits") {
                SectionHeader("Limits")
                Group(listOf(0, 1)) { index, position ->
                    if (index == 0)
                        StepperRow(
                            "Findings per review",
                            current.max_findings,
                            ReviewerForm.MAX_FINDINGS,
                            position,
                            "code-reviewer-findings",
                        ) {
                            draft = current.copy(max_findings = it)
                        }
                    else
                        StepperRow(
                            "Reviews per task",
                            current.max_rounds,
                            ReviewerForm.MAX_ROUNDS,
                            position,
                            "code-reviewer-rounds",
                        ) {
                            draft = current.copy(max_rounds = it)
                        }
                }
                SectionFooter("Agents are asked to stop requesting reviews after this many.")
            }
            item("instructions") {
                SectionHeader("Extra instructions")
                MobileTextField(
                    current.instructions,
                    { draft = current.copy(instructions = it) },
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .testTag("code-reviewer-instructions"),
                    placeholder = { Text("What matters most in your code") },
                    minLines = 3,
                    maxLines = 8,
                )
                SectionFooter("Added to every review.")
            }
            item("save") {
                val invalid = ReviewerForm.problem(current)
                Column(
                    Modifier.padding(horizontal = ScreenMargin, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (invalid != null && current != settings)
                        Text(
                            invalid,
                            Modifier.padding(horizontal = 16.dp),
                            style = type.footnote,
                            color = palette.destructive,
                        )
                    DButton(
                        "Save",
                        { store.codeReview.save(current) },
                        Modifier.fillMaxWidth().testTag("code-reviewer-save"),
                        large = true,
                        enabled =
                            invalid == null &&
                                !saving &&
                                daemonId != null &&
                                (current != settings || settings?.configured == false),
                        loading = saving,
                    )
                }
            }
        }
    }
}

/** A whole number within [range], stepped down and up. */
@Composable
internal fun StepperRow(
    title: String,
    value: Int,
    range: IntRange,
    position: Position,
    tag: String,
    onChange: (Int) -> Unit,
) {
    val shown = value.coerceIn(range)
    ListRow(
        title,
        Modifier.testTag(tag),
        position = position,
        trailing = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                StepButton("−", "Fewer", shown > range.first, "$tag-minus") {
                    onChange(shown - 1)
                }
                Text(
                    shown.toString(),
                    Modifier.widthIn(min = 22.dp).testTag("$tag-value"),
                    style = type.body.copy(fontWeight = FontWeight.Medium),
                    color = palette.label,
                )
                StepButton("+", "More", shown < range.last, "$tag-plus") { onChange(shown + 1) }
            }
        },
    )
}

@Composable
private fun StepButton(
    symbol: String,
    description: String,
    enabled: Boolean,
    tag: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(30.dp)
            .clip(CircleShape)
            .background(palette.fill)
            .graphicsAlpha(if (enabled) 1f else .4f)
            .then(if (enabled) Modifier.pressable(onClick = onClick) else Modifier)
            .semantics { contentDescription = description }
            .testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = type.body.copy(fontWeight = FontWeight.Medium), color = palette.label)
    }
}
