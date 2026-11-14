@file:OptIn(
    androidx.compose.material3.ExperimentalMaterial3Api::class,
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
)

package com.getdieter.mobile.conversation

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.Subagent
import com.getdieter.core.presentation.SubagentPresentation
import com.getdieter.core.presentation.TaskPlans
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import com.getdieter.mobile.tools.*

@Composable
internal fun CardPaneScreen(
    store: MobileStore,
    cardId: String,
    pane: CardPane,
    openUrl: (String) -> Unit,
) {
    when (pane) {
        CardPane.SUBAGENTS -> SubagentsScreen(store, cardId)
        CardPane.CHANGES -> ReviewScreen(store)
        CardPane.FILES -> FilesScreen(store, inConversation = true)
        CardPane.TERMINAL -> TerminalsScreen(store, inConversation = true)
        CardPane.PROCESSES -> ProcessesScreen(store)
    }
}

@Composable
private fun SubagentsScreen(store: MobileStore, cardId: String) {
    val view by store.conversation.slice.collectAsState()
    val agents = view.conversation?.subagents.orEmpty()
    Screen(ScreenChrome("Subagents", subtitle = view.card?.title.orEmpty())) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("subagents"),
            state = listState,
            contentPadding =
                PaddingValues(
                    start = ScreenMargin,
                    end = ScreenMargin,
                    top = padding.calculateTopPadding() + 8.dp,
                    bottom = padding.calculateBottomPadding() + 16.dp,
                ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (agents.isEmpty())
                item {
                    EmptyState(
                        Glyph.SUBAGENTS,
                        "No subagents",
                        "Delegated work appears here when the agent starts it.",
                        Modifier.padding(top = 60.dp),
                    )
                }
            items(agents, key = { it.id }) {
                SubagentCard(it, expandedByDefault = agents.size == 1)
            }
        }
    }
}

@Composable
internal fun SubagentCard(agent: Subagent, expandedByDefault: Boolean = false) {
    val now = rememberNow()
    val view = SubagentPresentation(agent, now)
    var expanded by rememberSaveable(agent.id) { mutableStateOf(expandedByDefault) }
    ContentCard(
        onClick = { expanded = !expanded },
        modifier = Modifier.testTag("subagent-${agent.id}"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(32.dp).clip(CircleShape).background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Glyph.SUBAGENTS, null, tint = palette.secondaryLabel, size = 16.dp)
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    view.title,
                    style = type.headline,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    view.identity,
                    style = type.footnote,
                    color = palette.secondaryLabel,
                    maxLines = 1,
                )
            }
            val tint = if (view.active) palette.info else palette.success
            Row(
                Modifier.clip(CircleShape)
                    .background(tint.copy(alpha = .14f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (view.active) LiveDot(tint, size = 7.dp)
                else
                    Icon(
                        Glyph.CHECK,
                        null,
                        tint = tint.readableOn(palette.cell),
                        size = 11.dp,
                        weight = GlyphWeight.BOLD,
                    )
                Spacer(Modifier.width(4.dp))
                Text(
                    view.statusLabel,
                    style = type.caption.copy(fontWeight = FontWeight.Medium),
                    color = tint.readableOn(palette.cell),
                )
            }
        }
        view.statusLine?.let {
            Spacer(Modifier.height(10.dp))
            Text(it, style = type.subheadline, color = palette.label)
        }
        view.contextFraction?.let {
            Spacer(Modifier.height(10.dp))
            ProgressBar(it.toFloat())
        }
        val metrics = (view.usageMetrics + view.elapsedLabel).filter { it.isNotEmpty() }
        if (metrics.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Text(metrics.joinToString(" · "), style = type.footnote, color = palette.secondaryLabel)
        }
        AnimatedVisibility(expanded) {
            Column(
                Modifier.padding(top = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Hairline()
                (view.narrative + view.technical).forEach { section ->
                    Text(
                        section.label,
                        style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.secondaryLabel,
                    )
                    Text(
                        section.value,
                        style = if (section.monospace) type.monoSmall else type.subheadline,
                        color = palette.label,
                    )
                }
            }
        }
    }
}

@Composable
internal fun TaskPlanCard(plan: com.getdieter.api.v1.TaskPlan, modifier: Modifier = Modifier) {
    val progress = TaskPlans.progress(plan)
    ContentCard(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Glyph.CHECKLIST, null, tint = palette.secondaryLabel, size = 18.dp)
            Spacer(Modifier.width(8.dp))
            Text("Plan", Modifier.weight(1f), style = type.headline, color = palette.label)
            Text(
                "${progress.completed} of ${progress.total}",
                style = type.footnote,
                color = palette.secondaryLabel,
            )
        }
        Spacer(Modifier.height(10.dp))
        ProgressBar(
            if (progress.total == 0) 0f else progress.completed.toFloat() / progress.total,
            color = palette.success,
        )
        Spacer(Modifier.height(6.dp))
        plan.phases.forEach { phase ->
            if (phase.name.isNotEmpty())
                Text(
                    phase.name,
                    Modifier.padding(top = 8.dp, bottom = 2.dp),
                    style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label,
                )
            phase.tasks.forEach { task ->
                val done = TaskPlans.finished(task)
                Row(Modifier.padding(vertical = 4.dp), verticalAlignment = Alignment.Top) {
                    Icon(
                        if (done) Glyph.CHECK_CIRCLE else Glyph.CIRCLE,
                        if (done) "Done" else "Open",
                        Modifier.padding(top = 1.dp),
                        tint = if (done) palette.success else palette.tertiaryLabel,
                        size = 18.dp,
                    )
                    Spacer(Modifier.width(10.dp))
                    Text(
                        TaskPlans.text(task),
                        style = type.subheadline,
                        color = if (done) palette.secondaryLabel else palette.label,
                    )
                }
            }
        }
    }
}
