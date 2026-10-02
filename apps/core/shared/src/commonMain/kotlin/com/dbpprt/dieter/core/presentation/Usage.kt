package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TokenUsage
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.core.board.Runtimes
import com.dbpprt.dieter.core.runtime.Timestamps
import kotlin.math.round
import kotlin.math.roundToInt
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/** How full the model's context was at the latest reported step. */
data class ContextUsage(val usedTokens: Long, val windowTokens: Long, val modelId: String?) {
    val fraction: Double get() = (usedTokens.toDouble() / windowTokens).coerceIn(0.0, 1.0)
    val percent: Int get() = (fraction * 100).roundToInt()

    /** Close enough to the limit to warn. */
    val nearLimit: Boolean get() = fraction > 0.85

    companion object {
        /**
         * The newest assistant step that reported usage. The step's own
         * window wins; [fallbackWindow] (the model's catalog window) fills in.
         */
        fun latest(messages: List<UiMessage>, fallbackWindow: Long = 0): ContextUsage? = latest(messages) { fallbackWindow }

        /**
         * The newest step that reported usage, scanning back past messages
         * without it, so a new turn keeps the last reported value until its
         * own step reports. The step's own window wins; [windowOf] gives the
         * window of the model the step named (null when it named none), 0
         * when unknown.
         */
        fun latest(messages: List<UiMessage>, windowOf: (modelId: String?) -> Long): ContextUsage? {
            for (message in messages.asReversed()) {
                val metadata = MessageMetadata.of(message) ?: continue
                val usage = metadata["usage"] as? JsonObject ?: continue
                val raw = usage["raw"] as? JsonObject
                val used = raw.long("totalTokens") ?: usage.long("totalTokens")
                    ?: ((usage.long("inputTokens") ?: 0) + (usage.long("outputTokens") ?: 0)).takeIf { it > 0 }
                    ?: continue
                if (used <= 0) continue
                val modelId = MessageMetadata.string(metadata, "modelId")
                val window = metadata.long("contextWindowTokens")?.takeIf { it > 0 } ?: windowOf(modelId).takeIf { it > 0 } ?: continue
                return ContextUsage(used, window, modelId)
            }
            return null
        }

        /**
         * The context window [catalog] lists for [provider]'s [reportedModel]
         * (the model a step named), else for the conversation's
         * [selectedModel] (the harness's default model when empty); 0 when
         * the catalog knows neither.
         */
        fun catalogWindow(catalog: HarnessCatalog?, provider: String, reportedModel: String?, selectedModel: String): Long {
            val harness = catalog?.harnesses?.firstOrNull { it.id == provider } ?: return 0
            fun window(model: String): Long? = harness.models.firstOrNull { it.id == model }?.context_window?.toLong()?.takeIf { it > 0 }
            return reportedModel?.trim()?.ifEmpty { null }?.let { window(it) } ?: window(selectedModel.ifEmpty { harness.default_model }) ?: 0
        }

        private fun JsonObject?.long(key: String): Long? = (this?.get(key) as? JsonPrimitive)?.longOrNull
    }
}

/** Compact token counts: 1.2k, 129k, 1.3M. */
object TokenCounts {
    /** A conversation's cumulative token usage, spelled out. */
    fun detail(usage: TokenUsage): String =
        if (usage.reported_messages == 0L) "Token usage was not reported by the provider."
        else "${usage.total_tokens} total tokens · ${usage.input_tokens} input · ${usage.output_tokens} output." +
            (if (usage.partial) " Partial provider data; input/output counts may be incomplete." else "") +
            " Cumulative conversation usage. Copied fork history is excluded; separate subagent counters are not added."

    fun compact(value: Long): String = when {
        value >= 1_000_000 -> format1(value / 1_000_000.0) + "M"
        value >= 100_000 -> "${(value / 1_000.0).roundToInt()}k"
        value >= 1_000 -> format1(value / 1_000.0) + "k"
        else -> value.toString()
    }

    /** "1.2k tokens", "1.3M tokens · partial", or "Tokens unavailable" when no message reported usage. */
    fun label(totalTokens: Long, reportedMessages: Long, partial: Boolean): String =
        if (reportedMessages <= 0) "Tokens unavailable" else "${compact(totalTokens)} tokens" + if (partial) " · partial" else ""

    /** One decimal place, POSIX style, regardless of the device locale. */
    fun format1(value: Double): String {
        val tenths = (value * 10).roundToInt()
        return "${tenths / 10}.${tenths % 10}"
    }
}

/** A conversation's cumulative token usage, as the daemon reported it. */
data class TokenUsagePresentation(val usage: TokenUsage) {
    val reported: Boolean get() = usage.reported_messages > 0
    val visible: Boolean get() = reported || usage.missing_messages > 0 || usage.partial

    /** "1.2k tokens", "1.3M tokens · partial", or "Tokens unavailable". */
    fun label(): String = TokenCounts.label(usage.total_tokens, usage.reported_messages, usage.partial)
}

/** Presentation of one delegated agent. */
data class SubagentPresentation(val agent: Subagent, val now: Instant) {
    private val suffix = Regex("\\s*\\((agent\\s+\\d+)\\)\\s*$", RegexOption.IGNORE_CASE)
    private val generic = setOf("agent", "subagent", "task", "worker")

    private fun clean(value: String) = value.replace(suffix, "").trim()

    val title: String
        get() {
            val name = clean(agent.name).ifEmpty { "Subagent" }
            if (name.lowercase() !in generic && name != "Subagent") return name
            return listOf(agent.task, agent.assignment, agent.description).map(::clean)
                .firstOrNull { it.isNotEmpty() && it.lowercase() !in generic && it != "Subagent" }
                ?: clean(agent.agent_type).ifEmpty { name }
        }

    val agentLabel: String get() = suffix.find(agent.name)?.groupValues?.get(1)?.lowercase() ?: agent.agent_type.ifEmpty { "agent" }

    val identity: String
        get() = listOf(listOf(agent.provider, agent.model).filter { it.isNotEmpty() }.joinToString("/"), agent.agent_source)
            .filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { "local" }

    val active: Boolean get() = Runtimes.isActive(agent.status) || agent.status.equals("pending", ignoreCase = true)

    /** Current context over the model's window, or null when either is unknown. */
    val contextFraction: Double? get() = if (agent.context_tokens > 0 && agent.context_window > 0) (agent.context_tokens.toDouble() / agent.context_window).coerceIn(0.0, 1.0) else null

    /** "1.3M processed", "129k / 1.0M context (13%)". */
    val usageMetrics: List<String>
        get() = buildList {
            if (agent.tokens > 0) add("${TokenCounts.compact(agent.tokens)} processed")
            contextFraction?.let { add("${TokenCounts.compact(agent.context_tokens)} / ${TokenCounts.compact(agent.context_window)} context (${(it * 100).roundToInt()}%)") }
        }

    val elapsed: Duration?
        get() {
            if (agent.duration_ms > 0) return agent.duration_ms.milliseconds
            val start = Timestamps.parse(agent.started_at) ?: return null
            val end = Timestamps.parse(agent.ended_at) ?: now
            return (end - start).takeIf { it.isPositive() }
        }

    val activity: String? get() = agent.activity.trim().ifBlank { null } ?: agent.current_tool.trim().takeIf { it.isNotBlank() }?.let { "Using $it" }

    /** The line under a transcript's subagent row: what it does now, else what it was asked. */
    val statusLine: String? get() = activity ?: agent.description.trim().ifEmpty { null }

    val completed: Boolean get() = agent.status.equals("completed", ignoreCase = true)

    /** The status the agent reported, "pending" before it reports one. */
    val statusLabel: String get() = agent.status.trim().ifEmpty { "pending" }

    /** "45s", "3m 12s"; empty before any time was measured. */
    val elapsedLabel: String
        get() {
            val seconds = elapsed?.inWholeSeconds ?: 0
            if (seconds <= 0) return ""
            return if (seconds < 60) "${seconds}s" else "${seconds / 60}m ${seconds % 60}s"
        }

    /** What the agent was asked to do: assignment, task, and description, without repeats. */
    val narrative: List<DetailSection>
        get() {
            val seen = HashSet<String>()
            return listOf("Assignment" to agent.assignment, "Task" to agent.task, "Description" to agent.description)
                .map { (label, value) -> DetailSection(label, value.trim()) }
                .filter { it.value.isNotEmpty() && seen.add(normalized(it.value)) }
        }

    /** The current tool call and recent output, shown in monospace. */
    val technical: List<DetailSection>
        get() = buildList {
            val tool = listOf(agent.current_tool.trim(), agent.current_tool_args.trim()).filter { it.isNotEmpty() }.joinToString("\n")
            if (tool.isNotEmpty()) add(DetailSection("Current tool", tool, monospace = true))
            val output = agent.recent_output.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
            if (output.isNotEmpty()) add(DetailSection("Recent output", output, monospace = true))
        }

    /** What the agent does now, unless it only repeats its title or assignment. */
    val nowLine: String?
        get() {
            val now = activity ?: return null
            val same = { other: String? -> other != null && normalized(other) == normalized(now) }
            return now.takeUnless { same(title) || same(narrative.firstOrNull()?.value) }
        }

    /** Everything beyond the headline narrative, for an expandable detail. */
    val details: List<DetailSection> get() = narrative.drop(1) + technical

    /** Tool calls, requests, token usage, cost, and capture state. */
    val operationalMetrics: List<String>
        get() = buildList {
            if (agent.tool_count > 0) add("${agent.tool_count} ${if (agent.tool_count == 1L) "tool call" else "tool calls"}")
            if (agent.requests > 0) add("${agent.requests} ${if (agent.requests == 1L) "request" else "requests"}")
            addAll(usageMetrics)
            if (agent.cost > 0) add(cost(agent.cost))
            if (agent.detached) add("detached")
            if (agent.transcript_available) add("transcript captured")
        }

    /** The compact line under a transcript's subagent row: model, tools, usage. */
    val summaryMetrics: List<String>
        get() = listOfNotNull(agent.model.ifBlank { null }, agent.tool_count.takeIf { it > 0 }?.let { "$it tools" }) + usageMetrics

    private fun normalized(value: String) = clean(value).replace(Regex("\\s+"), " ").lowercase()

    data class DetailSection(val label: String, val value: String, val monospace: Boolean = false) {
        /** At most [maxChars], so a runaway output cannot stall the layout. */
        fun bounded(maxChars: Int = 4_000): String = if (value.length <= maxChars) value else value.take(maxChars).trimEnd() + "…"
    }

    companion object {
        /** US dollars: four decimals under a cent, else two. */
        fun cost(value: Double): String {
            val decimals = if (value < 0.01) 4 else 2
            var scale = 1L
            repeat(decimals) { scale *= 10 }
            val units = round(value * scale).toLong()
            return "$" + (units / scale) + "." + (units % scale).toString().padStart(decimals, '0')
        }

        fun active(agents: List<Subagent>): Int = agents.count { SubagentPresentation(it, Instant.DISTANT_PAST).active }
    }
}
