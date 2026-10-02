package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.PendingTool
import com.dbpprt.dieter.api.v1.ProviderStatus
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.time.Instant

/** What the agent is doing right now, in priority order of the cases below. */
sealed interface LiveActivity {
    data object Stopping : LiveActivity
    data class Provider(val status: ProviderStatus) : LiveActivity
    data class Approval(val tool: String) : LiveActivity
    data class Tool(val activity: ToolActivity, val othersRunning: Int = 0) : LiveActivity
    data object Writing : LiveActivity
    data class Reasoning(val summary: String) : LiveActivity
    data class Planning(val task: String) : LiveActivity
    data object Starting : LiveActivity
    data object Thinking : LiveActivity

    fun english(): String = when (this) {
        Stopping -> "Stopping…"
        is Provider -> ProviderStatuses.label(status) ?: "Thinking…"
        is Approval -> "Waiting for approval: $tool"
        is Tool -> activity.english() + if (othersRunning > 0) " · +$othersRunning ${if (othersRunning == 1) "tool" else "tools"}" else ""
        Writing -> "Writing response…"
        is Reasoning -> summary
        is Planning -> task
        Starting -> "Starting agent…"
        Thinking -> "Thinking…"
    }
}

object ProviderStatuses {
    fun active(status: ProviderStatus?): Boolean = status != null && status.state.isNotEmpty()

    /** A retrying provider stream, described once for every client. */
    fun label(status: ProviderStatus?): String? = when (status?.state?.lowercase()) {
        "waiting-for-network" -> "Reconnecting to provider (waiting for network)…"
        "reconnecting" -> if (status.attempt > 0 && status.max_attempts > 0) "Reconnecting to provider (${status.attempt}/${status.max_attempts})…" else "Reconnecting to provider…"
        else -> null
    }
}

/** Live activity of the current turn: only the messages after the latest user message count. */
object LiveActivities {
    fun resolve(
        messages: List<UiMessage>,
        pendingTools: List<PendingTool> = emptyList(),
        plans: List<TaskPlan> = emptyList(),
        showReasoning: Boolean = false,
        conversationStatus: String? = null,
        cardRuntime: String? = null,
        providerStatus: ProviderStatus? = null,
    ): LiveActivity {
        if (listOf(conversationStatus, cardRuntime).any { it?.trim()?.lowercase() == "cancelling" }) return LiveActivity.Stopping
        if (ProviderStatuses.label(providerStatus) != null) return LiveActivity.Provider(providerStatus!!)
        val turn = turn(messages)
        val parts = turn.flatMap { it.parts }
        parts.lastOrNull { Parts.isToolCall(it) && it.state == "approval-requested" }?.let { return LiveActivity.Approval(Tools.title(Parts.toolName(it))) }
        val running = parts.filter { Parts.isToolCall(it) && Tools.isRunning(it) }
        running.lastOrNull()?.let { return LiveActivity.Tool(activity(it), running.size - 1) }
        unfinished(parts, pendingTools).lastOrNull()?.let { pending ->
            return LiveActivity.Tool(Tools.activity(pending.tool_name, pending.input_json.utf8(), pending.input_preview))
        }
        val last = parts.lastOrNull { it.type != "step-start" }
        if (last != null) {
            if (last.type == "text" && last.state == "streaming") return LiveActivity.Writing
            if (showReasoning) reasoning(last)?.let { return it }
        }
        val turnIds = turn.mapTo(HashSet()) { it.id }
        plans.lastOrNull { it.state == "active" && it.message_id in turnIds }?.let { plan ->
            plan.phases.flatMap { it.tasks }.firstOrNull { it.status == "in_progress" }?.let { task ->
                task.active_form.ifBlank { task.content }.takeIf { it.isNotBlank() }?.let { return LiveActivity.Planning(Tools.compact(it)) }
            }
        }
        if (listOf(conversationStatus, cardRuntime).any { it?.trim()?.lowercase() == "starting" } && parts.isEmpty()) return LiveActivity.Starting
        return LiveActivity.Thinking
    }

    /**
     * [plain], resolved without reasoning, as [resolve] would show it with
     * reasoning: the turn's latest reasoning summary where it takes precedence.
     */
    fun withReasoning(plain: LiveActivity, messages: List<UiMessage>): LiveActivity {
        if (plain !is LiveActivity.Planning && plain != LiveActivity.Starting && plain != LiveActivity.Thinking) return plain
        val last = turn(messages).flatMap { it.parts }.lastOrNull { it.type != "step-start" } ?: return plain
        return reasoning(last) ?: plain
    }

    /** The [pendingTools] the current turn's transcript has not finished: running tool calls it does not show yet. */
    fun unfinishedPendingTools(messages: List<UiMessage>, pendingTools: List<PendingTool>): List<PendingTool> =
        if (pendingTools.isEmpty()) emptyList() else unfinished(turn(messages).flatMap { it.parts }, pendingTools)

    private fun unfinished(parts: List<MessagePart>, pendingTools: List<PendingTool>): List<PendingTool> {
        if (pendingTools.isEmpty()) return emptyList()
        val finished = parts.filter { Parts.isToolCall(it) && !Tools.isRunning(it) }.mapTo(HashSet()) { it.tool_call_id }
        return pendingTools.filter { it.tool_call_id.isEmpty() || it.tool_call_id !in finished }
    }

    /** The assistant messages after the latest user message. */
    private fun turn(messages: List<UiMessage>): List<UiMessage> =
        messages.drop(messages.indexOfLast(Parts::isUser) + 1).filter { it.role.equals("assistant", ignoreCase = true) }

    private fun reasoning(part: MessagePart): LiveActivity.Reasoning? =
        if (Parts.isReasoning(part)) reasoningSummary(part.text)?.let(LiveActivity::Reasoning) else null

    private fun activity(part: MessagePart) = Tools.activity(Parts.toolName(part), part.input_json.utf8(), part.input_preview)

    /** The latest bold line or heading of the reasoning, else a short single-line text. */
    fun reasoningSummary(text: String): String? {
        val tail = text.takeLast(4096)
        for (line in tail.lines().asReversed()) {
            val trimmed = line.trim()
            Regex("^\\*\\*(.+?)\\*\\*").find(trimmed)?.let { match -> Tools.compact(match.groupValues[1]).takeIf { it.isNotEmpty() }?.let { return it } }
            Regex("^#{1,6} (.+)$").find(trimmed)?.let { match -> match.groupValues[1].trim(' ', '#').takeIf { it.isNotEmpty() }?.let { return Tools.compact(it) } }
        }
        val whole = text.trim()
        return whole.takeIf { it.isNotEmpty() && it.length <= 120 && '\n' !in it && !it.startsWith("*") }
    }

    /** When the current turn started: the latest user message's time, else the runtime's. */
    fun turnStart(messages: List<UiMessage>, runtimeUpdatedAt: String?): Instant? =
        messages.lastOrNull(Parts::isUser)?.let(MessageMetadata::createdAt) ?: Timestamps.parse(runtimeUpdatedAt)
}
