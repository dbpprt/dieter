package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage

enum class StepKind {
    TEXT, REASONING, TOOL, ATTENTION, ATTACHMENT, OTHER,

    /** The message's delegated agents, where the first delegating tool call was. */
    SUBAGENTS,
}

/** One visible part of a message; adjacent prose is coalesced into one step. */
data class TimelineStep(
    /** Stable: `<message>:part:<index of the first part>`. */
    val id: String,
    val messageId: String,
    val kind: StepKind,
    val part: MessagePart,
    /** Coalesced text for prose steps. */
    val text: String = part.text,
) {
    val routine: Boolean get() = kind == StepKind.TOOL && !Parts.isApprovalTool(part) || kind == StepKind.REASONING
}

/** Consecutive routine steps within one message fold into one disclosure. */
data class StepGroup(val id: String, val steps: List<TimelineStep>, val activity: Boolean)

/** Counts for an activity disclosure title, e.g. "Reasoning · 1 edit · 1 command". */
data class ActivitySummary(val reasoning: Int, val tools: Map<ToolCategory, Int>) {
    fun english(): String {
        val parts = mutableListOf<String>()
        if (reasoning > 0) parts += "Reasoning"
        for (category in ORDER) {
            val count = tools[category] ?: continue
            parts += "$count ${noun(category, count)}"
        }
        return parts.joinToString(" · ").ifEmpty { "Activity" }
    }

    companion object {
        private val ORDER = listOf(ToolCategory.EDIT, ToolCategory.COMMAND, ToolCategory.WRITE, ToolCategory.READ, ToolCategory.SEARCH, ToolCategory.BROWSER, ToolCategory.OTHER)

        fun of(steps: List<TimelineStep>) = ActivitySummary(
            reasoning = steps.count { it.kind == StepKind.REASONING },
            tools = steps.filter { it.kind == StepKind.TOOL }.groupingBy { Tools.category(Parts.toolName(it.part)) }.eachCount(),
        )

        fun noun(category: ToolCategory, count: Int): String {
            val (one, many) = when (category) {
                ToolCategory.EDIT -> "edit" to "edits"
                ToolCategory.COMMAND -> "command" to "commands"
                ToolCategory.WRITE -> "write" to "writes"
                ToolCategory.READ -> "read" to "reads"
                ToolCategory.SEARCH -> "search" to "searches"
                ToolCategory.BROWSER -> "browser action" to "browser actions"
                ToolCategory.OTHER -> "tool call" to "tool calls"
            }
            return if (count == 1) one else many
        }
    }
}

sealed interface TimelineItem {
    /** Stable across streaming, so disclosure state survives new tool calls. */
    val id: String
    val messageIds: List<String>

    /** A user or assistant message with its visible steps, plans, and delegated agents. */
    data class Message(
        override val id: String,
        val message: UiMessage,
        val user: Boolean,
        val groups: List<StepGroup>,
        val plans: List<TaskPlan> = emptyList(),
        val subagents: List<Subagent> = emptyList(),
    ) : TimelineItem {
        override val messageIds: List<String> get() = listOf(message.id)
        val steps: List<TimelineStep> get() = groups.flatMap { it.steps }
    }

    /** Consecutive assistant messages that only worked (tools, reasoning), shown as one summary. */
    data class Activity(override val id: String, override val messageIds: List<String>, val steps: List<TimelineStep>) : TimelineItem {
        val summary: ActivitySummary get() = ActivitySummary.of(steps)
    }
}

data class TimelineOptions(
    val showReasoning: Boolean = false,
    /** Drop tool calls that only mirror a rendered task plan. */
    val hidePlanTools: Boolean = true,
)

data class Timeline(val items: List<TimelineItem>, val unattachedPlans: List<TaskPlan>)

/**
 * Builds the transcript timeline. Grouping follows the macOS and iOS clients:
 * adjacent tool-only messages form one row, and rows that are nothing but
 * routine activity fold into one summary.
 */
object TimelineBuilder {
    private val planTools = setOf("todowrite", "taskcreate", "taskupdate", "tasklist", "taskget", "todo", "board_task_plan", "update_plan")

    fun build(
        messages: List<UiMessage>,
        queuedIds: Set<String> = emptySet(),
        plans: List<TaskPlan> = emptyList(),
        subagents: List<Subagent> = emptyList(),
        options: TimelineOptions = TimelineOptions(),
    ): Timeline {
        val plansByMessage = plans.filter { it.message_id.isNotEmpty() }.groupBy { it.message_id }
        val agentsByMessage = subagents.filter { it.message_id.isNotEmpty() }.groupBy { it.message_id }
        val rows = mutableListOf<TimelineItem>()
        var toolRun = mutableListOf<Pair<String, List<TimelineStep>>>()

        fun flushToolRun() {
            if (toolRun.isEmpty()) return
            rows += TimelineItem.Activity("tools:${toolRun.first().first}", toolRun.map { it.first }, toolRun.flatMap { it.second })
            toolRun = mutableListOf()
        }

        for ((position, message) in messages.withIndex()) {
            if (message.id.isNotEmpty() && message.id in queuedIds) continue
            val key = message.id.ifEmpty { "position:$position" }
            val user = Parts.isUser(message)
            val messagePlans = plansByMessage[message.id].orEmpty()
            val messageAgents = agentsByMessage[message.id].orEmpty()
            val steps = steps(message, key, options, hidePlanTools = options.hidePlanTools && messagePlans.isNotEmpty(), subagents = messageAgents)
            if (!user && steps.isEmpty() && messagePlans.isEmpty() && messageAgents.isEmpty()) continue
            val toolOnly = !user && messagePlans.isEmpty() && messageAgents.isEmpty() && steps.isNotEmpty() && steps.all { it.routine }
            if (toolOnly) {
                toolRun += key to steps
                continue
            }
            flushToolRun()
            rows += TimelineItem.Message("message:$key", message, user, group(steps), messagePlans, messageAgents)
        }
        flushToolRun()
        val loaded = messages.mapTo(HashSet()) { it.id }
        return Timeline(merge(rows), plans.filter { it.message_id.isNotEmpty() && it.message_id !in loaded })
    }

    /** Adjacent activity rows become one; its ID is the first row's, so it stays stable while it grows. */
    private fun merge(rows: List<TimelineItem>): List<TimelineItem> {
        val merged = mutableListOf<TimelineItem>()
        for (row in rows) {
            val last = merged.lastOrNull()
            if (row is TimelineItem.Activity && last is TimelineItem.Activity) {
                merged[merged.lastIndex] = TimelineItem.Activity(last.id, last.messageIds + row.messageIds, last.steps + row.steps)
            } else {
                merged += row
            }
        }
        return merged
    }

    /**
     * The visible steps of one message. Tool calls that delegated to one of
     * [subagents] become a single [StepKind.SUBAGENTS] step at the first
     * delegating call; agents without one follow the message's other steps.
     */
    fun steps(message: UiMessage, key: String, options: TimelineOptions, hidePlanTools: Boolean, subagents: List<Subagent> = emptyList()): List<TimelineStep> {
        val steps = mutableListOf<TimelineStep>()
        val delegated = subagents.mapNotNullTo(HashSet()) { it.parent_tool_call_id.ifEmpty { null } }
        var agentsShown = false
        fun showAgents() {
            if (agentsShown || subagents.isEmpty()) return
            agentsShown = true
            steps += TimelineStep("$key:subagents", message.id, StepKind.SUBAGENTS, MessagePart(), text = "")
        }
        for ((index, part) in message.parts.withIndex()) {
            if (!Parts.isVisible(part, options.showReasoning)) continue
            if (hidePlanTools && Parts.isToolCall(part) && normalized(Parts.toolName(part)) in planTools) continue
            if (Parts.isToolCall(part) && part.tool_call_id.isNotEmpty() && part.tool_call_id in delegated && !Parts.isApprovalTool(part)) {
                showAgents()
                continue
            }
            val kind = when {
                Parts.isToolCall(part) -> StepKind.TOOL
                Parts.isReasoning(part) -> StepKind.REASONING
                Parts.needsAttention(part) -> StepKind.ATTENTION
                part.type == "text" -> StepKind.TEXT
                part.type in setOf("file", "attachment", "image") -> StepKind.ATTACHMENT
                else -> StepKind.OTHER
            }
            val previous = steps.lastOrNull()
            if (kind == StepKind.TEXT && previous?.kind == StepKind.TEXT) {
                steps[steps.lastIndex] = previous.copy(text = previous.text + "\n\n" + part.text)
                continue
            }
            steps += TimelineStep("$key:part:$index", message.id, kind, part)
        }
        showAgents()
        return steps
    }

    /** Consecutive routine steps of one message form a group; each other step stands alone. */
    fun group(steps: List<TimelineStep>): List<StepGroup> {
        val groups = mutableListOf<StepGroup>()
        for (step in steps) {
            val last = groups.lastOrNull()
            if (step.routine && last?.activity == true) groups[groups.lastIndex] = last.copy(steps = last.steps + step)
            else groups += StepGroup(step.id, listOf(step), step.routine)
        }
        return groups
    }

    /** The first group to show: from [fromId] when given, else the last [INITIAL_GROUPS]. */
    fun visibleStart(groups: List<StepGroup>, fromId: String? = null): Int =
        fromId?.let { id -> groups.indexOfFirst { it.id == id }.takeIf { it >= 0 } } ?: maxOf(0, groups.size - INITIAL_GROUPS)

    const val INITIAL_GROUPS = 12

    private fun normalized(name: String) = name.trim().lowercase().replace('-', '_').replace(' ', '_')
}
