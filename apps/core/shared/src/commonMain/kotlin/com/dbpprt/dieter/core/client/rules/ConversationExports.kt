package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.client.v1.SubagentDetail
import com.dbpprt.dieter.client.v1.SubagentSummary
import com.dbpprt.dieter.client.v1.TaskPlanSummary
import com.dbpprt.dieter.client.v1.MessageDelivery
import com.dbpprt.dieter.client.v1.TimelineMessages
import com.dbpprt.dieter.client.v1.TimelineRows
import com.dbpprt.dieter.core.client.timelineItem
import com.dbpprt.dieter.core.presentation.Parts
import com.dbpprt.dieter.core.presentation.SubagentPresentation
import com.dbpprt.dieter.core.presentation.TaskPlans
import com.dbpprt.dieter.core.presentation.TimelineBuilder
import com.dbpprt.dieter.core.presentation.TimelineOptions
import kotlin.time.Instant

/**
 * Conversation rules views call while rendering a transcript row or acting
 * on it: how much of a long message shows, what "copy message" copies, and
 * how task plans and delegated agents read. The timeline itself arrives in
 * the conversation slice; [timelineRows] lays out messages the core does not
 * hold, e.g. a fixture's.
 */
object ConversationExports {
    /**
     * The index of the first step group a long message shows: [fromId]'s
     * group while it is still there, else the last [initialGroups]. Empty
     * [fromId] means none was pinned yet.
     */
    fun visibleStart(groupIds: List<String>, fromId: String): Int = TimelineBuilder.visibleStartOf(groupIds, fromId.ifEmpty { null })

    /** How many step groups a long message reveals at a time, from its tail. */
    fun initialGroups(): Int = TimelineBuilder.INITIAL_GROUPS

    /**
     * [messages] laid out as `ConversationSlice.timeline` lays out a
     * conversation's, without task plans or delegated agents; messages in
     * [queuedIds] are not rows, and user messages read as synced.
     */
    fun timelineRows(messages: TimelineMessages, queuedIds: List<String>, showReasoning: Boolean): TimelineRows {
        val timeline = TimelineBuilder.build(messages.messages, queuedIds.toSet(), options = TimelineOptions(showReasoning = showReasoning))
        return TimelineRows(timeline.items.map { timelineItem(it, { MessageDelivery.MESSAGE_DELIVERY_SYNCED }, { false }) })
    }

    /** What a row's "copy message" action copies: its messages' prose parts as written, separated by a blank line. */
    fun copyText(messages: TimelineMessages): String = Parts.copyText(messages.messages)

    /** [plan]'s progress (completed counts abandoned tasks) and each task's wording. */
    fun taskPlan(plan: TaskPlan): TaskPlanSummary {
        val progress = TaskPlans.progress(plan)
        val tasks = plan.phases.flatMap { it.tasks }
        return TaskPlanSummary(
            completed = progress.completed, total = progress.total, active = progress.active,
            task_texts = tasks.map(TaskPlans::text),
        )
    }

    /** [agent] as transcript rows and the subagents pane show it; the elapsed time runs to [nowMillis] while it works. */
    fun subagent(agent: Subagent, nowMillis: Long): SubagentSummary {
        val presented = SubagentPresentation(agent, Instant.fromEpochMilliseconds(nowMillis))
        return SubagentSummary(
            title = presented.title, agent_label = presented.agentLabel, identity = presented.identity,
            active = presented.active, completed = presented.completed,
            status_line = presented.statusLine.orEmpty(), elapsed = presented.elapsedLabel,
            context_fraction = presented.contextFraction ?: -1.0, usage_metrics = presented.usageMetrics,
            narrative = presented.narrative.map(::detail), details = presented.details.map(::detail),
        )
    }

    private fun detail(section: SubagentPresentation.DetailSection) = SubagentDetail(label = section.label, text = section.bounded(), monospace = section.monospace)
}
