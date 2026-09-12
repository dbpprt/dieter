package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.PendingTool
import com.dbpprt.dieter.v1.TaskPlan
import com.dbpprt.dieter.v1.UiMessage
import java.time.Instant

/**
 * Describes the activity reported by the current provider turn. Historical
 * tools and locally queued follow-ups must never leak into the live badge.
 */
internal object ConversationActivityPresentation {
    private val activeStatuses = setOf("starting", "running", "working", "streaming", "cancelling")
    private val runningToolStates = setOf("input-available", "running", "executing")

    fun isActive(conversationStatus: String, cardRuntime: String): Boolean =
        normalized(conversationStatus) in activeStatuses || normalized(cardRuntime) in activeStatuses

    fun turnStartMillis(messages: List<UiMessage>, runtimeUpdatedAt: String): Long? {
        messages.lastOrNull(::isUser)?.metadataJson?.toStringUtf8()
            ?.takeIf(String::isNotBlank)
            ?.let(::jsonStringFields)
            ?.get("createdAt")
            ?.takeIf(String::isNotBlank)
            ?.let(::parseInstantMillis)
            ?.let { return it }
        return parseInstantMillis(runtimeUpdatedAt)
    }

    fun liveLabel(
        messages: List<UiMessage>,
        pendingTools: List<PendingTool>,
        plans: List<TaskPlan>,
        showReasoning: Boolean = true,
        conversationStatus: String = "",
        cardRuntime: String = "",
    ): String {
        if (listOf(conversationStatus, cardRuntime).any { normalized(it) == "cancelling" }) {
            return "Stopping…"
        }

        val turnStart = messages.indexOfLast(::isUser).let { if (it < 0) 0 else it + 1 }
        val assistants = messages.drop(turnStart).filter { normalized(it.role) == "assistant" }
        val parts = assistants.flatMap { it.partsList }
        val tools = parts.filter(::isToolCall)
        tools.lastOrNull { normalized(it.state) == "approval-requested" }?.let { approval ->
            return "Waiting for approval: ${toolTitle(effectiveToolName(approval))}"
        }
        val running = tools.filter { part ->
            normalized(part.state) in runningToolStates && !part.hasOutput && part.errorText.isBlank()
        }
        running.lastOrNull()?.let { tool ->
            val label = toolLabel(effectiveToolName(tool), tool.inputJson.toStringUtf8(), tool.inputPreview)
            return if (running.size > 1) {
                "$label · +${running.size - 1} ${if (running.size == 2) "tool" else "tools"}"
            } else {
                label
            }
        }

        val finishedIds = tools.filter { normalized(it.state) !in runningToolStates }
            .mapTo(hashSetOf(), MessagePart::getToolCallId)
        pendingTools.lastOrNull { it.toolCallId.isBlank() || it.toolCallId !in finishedIds }?.let { tool ->
            return toolLabel(tool.toolName, tool.inputJson.toStringUtf8(), tool.inputPreview)
        }

        parts.lastOrNull { normalized(it.type) != "step-start" }?.let { latest ->
            if (normalized(latest.type) == "text" && normalized(latest.state) == "streaming") {
                return "Writing response…"
            }
            if (showReasoning && normalized(latest.type) in setOf("reasoning", "thinking")) {
                reasoningSummary(latest.text)?.let { return it }
            }
        }

        val currentMessageIds = assistants.mapNotNullTo(hashSetOf()) { it.id.takeIf(String::isNotBlank) }
        plans.lastOrNull { it.messageId in currentMessageIds && normalized(it.state) == "active" }
            ?.phasesList
            ?.flatMap { it.tasksList }
            ?.firstOrNull { normalized(it.status) == "in_progress" }
            ?.let { compact(it.activeForm.ifBlank { it.content }) }
            ?.takeIf(String::isNotBlank)
            ?.let { return it }

        if (listOf(conversationStatus, cardRuntime).any { normalized(it) == "starting" } && parts.isEmpty()) {
            return "Starting agent…"
        }
        return "Thinking…"
    }

    private fun toolLabel(name: String, inputJson: String, preview: String): String {
        val raw = inputJson.ifBlank { preview }
        val fields = raw.takeIf { it.toByteArray().size <= 16_384 }
            ?.let(::jsonStringFields)
        fields?.get("description")
            ?.takeIf(String::isNotBlank)
            ?.let(::compact)
            ?.takeIf(String::isNotBlank)
            ?.let { return it }

        val leaf = normalized(name).substringAfterLast("__")
        val kind = leaf.substringAfterLast('.').substringAfterLast('/')
        val (action, keys) = when (kind) {
            "read", "read_file", "readfile" -> "Reading" to listOf("path", "file_path", "filePath")
            "edit", "write", "write_file", "edit_file", "multiedit", "multi_edit", "apply_patch", "patch" ->
                "Editing" to listOf("path", "file_path", "filePath")
            "bash", "shell", "command", "exec", "exec_command", "terminal" ->
                "Running" to listOf("command", "cmd", "argv")
            "grep", "glob", "search", "websearch", "web_search" -> "Searching" to listOf("query", "pattern")
            "webfetch", "web_fetch", "fetch" -> "Fetching" to listOf("url")
            "write_stdin", "wait" -> return "Waiting for command…"
            else -> return "Using ${toolTitle(name)}…"
        }
        var target = keys.firstNotNullOfOrNull { key -> fields?.get(key) }.orEmpty()
        if (fields == null && !preview.startsWith("{") && !preview.startsWith("[") &&
            !preview.startsWith("*** Begin Patch")
        ) {
            target = preview
        }
        if (action == "Reading" || action == "Editing") target = target.substringAfterLast('/').substringAfterLast('\\')
        compact(target).takeIf(String::isNotBlank)?.let { return compact("$action $it") }
        return when (action) {
            "Reading" -> "Reading file…"
            "Editing" -> "Editing files…"
            "Running" -> "Running command…"
            "Fetching" -> "Fetching page…"
            else -> "Searching…"
        }
    }

    private fun reasoningSummary(text: String): String? {
        text.takeLast(4_096).lineSequence().toList().asReversed().forEach { line ->
            val value = line.trim()
            if (value.startsWith("**")) {
                val end = value.indexOf("**", startIndex = 2)
                if (end > 2) compact(value.substring(2, end)).takeIf(String::isNotBlank)?.let { return it }
            }
            val hashes = value.takeWhile { it == '#' }.length
            if (hashes in 1..6 && value.getOrNull(hashes) == ' ') {
                compact(value.drop(hashes).trim(' ', '#')).takeIf(String::isNotBlank)?.let { return it }
            }
        }
        val trimmed = text.trim()
        if (trimmed.isBlank() || trimmed.length > 120 || '\n' in trimmed || trimmed.startsWith('*')) return null
        return compact(trimmed)
    }

    private fun parseInstantMillis(value: String): Long? = value.takeIf(String::isNotBlank)
        ?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }

    private fun effectiveToolName(part: MessagePart): String = part.toolName.ifBlank { part.type.removePrefix("tool-") }

    private fun isToolCall(part: MessagePart): Boolean =
        normalized(part.type) == "dynamic-tool" || normalized(part.type).startsWith("tool-")

    private fun toolTitle(name: String): String = compact(name.substringAfterLast("__").replace('_', ' '))
        .ifBlank { "tool" }

    private fun compact(value: String): String {
        val text = value.take(1_024).trim().split(Regex("\\s+")).filter(String::isNotBlank).joinToString(" ")
        return if (text.length > 120) text.take(119) + "…" else text
    }

    private fun normalized(value: String): String = value.trim().lowercase()

    private fun isUser(message: UiMessage): Boolean = normalized(message.role) in setOf("user", "human")

    private fun jsonStringFields(raw: String): Map<String, String>? {
        val value = raw.trim()
        if (!value.startsWith('{') || !value.endsWith('}')) return null
        val stringToken = "\"(?:\\\\.|[^\"\\\\])*\""
        val arrayToken = "\\[(?:\\s*$stringToken\\s*,?)*\\]"
        val pair = Regex("($stringToken)\\s*:\\s*($stringToken|$arrayToken)")
        return buildMap {
            pair.findAll(value).forEach { match ->
                val key = decodeJsonString(match.groupValues[1]) ?: return@forEach
                val encoded = match.groupValues[2]
                val decoded = if (encoded.startsWith('[')) {
                    Regex(stringToken).findAll(encoded)
                        .mapNotNull { decodeJsonString(it.value) }
                        .joinToString(" ")
                } else {
                    decodeJsonString(encoded).orEmpty()
                }
                put(key, decoded)
            }
        }
    }

    private fun decodeJsonString(encoded: String): String? {
        if (encoded.length < 2 || encoded.first() != '"' || encoded.last() != '"') return null
        val result = StringBuilder(encoded.length - 2)
        var index = 1
        while (index < encoded.lastIndex) {
            val char = encoded[index++]
            if (char != '\\') {
                result.append(char)
                continue
            }
            if (index >= encoded.lastIndex) return null
            when (val escaped = encoded[index++]) {
                '"', '\\', '/' -> result.append(escaped)
                'b' -> result.append('\b')
                'f' -> result.append('\u000C')
                'n' -> result.append('\n')
                'r' -> result.append('\r')
                't' -> result.append('\t')
                'u' -> {
                    if (index + 4 > encoded.lastIndex) return null
                    val code = encoded.substring(index, index + 4).toIntOrNull(16) ?: return null
                    result.append(code.toChar())
                    index += 4
                }
                else -> return null
            }
        }
        return result.toString()
    }
}

internal fun elapsedActivityLabel(startedAtMillis: Long, nowMillis: Long): String {
    val seconds = ((nowMillis - startedAtMillis).coerceAtLeast(0L) / 1_000L)
    val hours = seconds / 3_600L
    val minutes = (seconds % 3_600L) / 60L
    val remainder = seconds % 60L
    return if (hours > 0L) "%d:%02d:%02d".format(hours, minutes, remainder)
    else "%d:%02d".format(minutes, remainder)
}
