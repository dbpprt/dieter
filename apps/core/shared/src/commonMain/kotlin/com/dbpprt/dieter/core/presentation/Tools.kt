package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.MessagePart
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

enum class ToolCategory { EDIT, COMMAND, WRITE, READ, SEARCH, BROWSER, OTHER }

enum class ToolStatus { RUNNING, COMPLETED, FAILED, NEEDS_APPROVAL, DENIED, OTHER }

/** What a tool call is doing, for live labels: an action and its target. */
enum class ToolAction {
    READING, EDITING, RUNNING, SEARCHING, FETCHING, WAITING_FOR_COMMAND, USING,

    /** The tool described its own action; the target is that description. */
    DESCRIBED,
}

data class ToolActivity(val action: ToolAction, val target: String?, val tool: String) {
    /** English rendering; platforms may localize from the structured fields. */
    fun english(): String = when (action) {
        ToolAction.DESCRIBED -> target.orEmpty()
        ToolAction.WAITING_FOR_COMMAND -> "Waiting for command…"
        ToolAction.USING -> Tools.compact("Using $tool…")
        else -> target?.let { Tools.compact("${verb(action)} $it") } ?: fallback(action)
    }

    private fun verb(action: ToolAction) = when (action) {
        ToolAction.READING -> "Reading"
        ToolAction.EDITING -> "Editing"
        ToolAction.RUNNING -> "Running"
        ToolAction.SEARCHING -> "Searching"
        ToolAction.FETCHING -> "Fetching"
        else -> ""
    }

    private fun fallback(action: ToolAction) = when (action) {
        ToolAction.READING -> "Reading file…"
        ToolAction.EDITING -> "Editing files…"
        ToolAction.RUNNING -> "Running command…"
        ToolAction.SEARCHING -> "Searching…"
        ToolAction.FETCHING -> "Fetching page…"
        else -> "Working…"
    }
}

/** Tool call naming, categories, states, and previews. */
object Tools {
    private val running = setOf("input-available", "running", "executing")
    private val completed = setOf("completed", "success", "done", "output-available")
    private val failed = setOf("output-error", "error", "failed")

    /** The last segment after `__`, `.` or `/`, lowercased: `mcp__files__read_file` → `read_file`. */
    fun kind(name: String): String = name.lowercase().substringAfterLast("__").substringAfterLast('.').substringAfterLast('/')

    /** Categories by exact tool kind, falling back to Android's substring rules. */
    fun category(name: String): ToolCategory {
        val kind = kind(name)
        return when {
            kind in setOf("edit", "apply_patch", "patch", "multi_edit", "multiedit", "str_replace_editor", "edit_file") -> ToolCategory.EDIT
            kind in setOf("bash", "shell", "command", "exec", "exec_command", "write_stdin", "terminal") -> ToolCategory.COMMAND
            kind in setOf("write", "write_file", "create_file") -> ToolCategory.WRITE
            kind in setOf("read", "read_file", "readfile", "view_file") -> ToolCategory.READ
            kind in setOf("grep", "glob", "search", "find", "websearch", "web_search") -> ToolCategory.SEARCH
            Regex("browser|navigate|click|screenshot").containsMatchIn(kind) -> ToolCategory.BROWSER
            Regex("apply.?patch|edit|replace").containsMatchIn(kind) -> ToolCategory.EDIT
            Regex("bash|shell|terminal|exec|command").containsMatchIn(kind) -> ToolCategory.COMMAND
            Regex("write|create.?file").containsMatchIn(kind) -> ToolCategory.WRITE
            Regex("read|view.?file").containsMatchIn(kind) -> ToolCategory.READ
            Regex("grep|glob|search|find").containsMatchIn(kind) -> ToolCategory.SEARCH
            else -> ToolCategory.OTHER
        }
    }

    fun status(part: MessagePart): ToolStatus {
        val state = part.state.lowercase()
        return when {
            "denied" in state || "rejected" in state -> ToolStatus.DENIED
            state == "approval-requested" || Parts.isApprovalTool(part) -> ToolStatus.NEEDS_APPROVAL
            state in failed || part.error_text.isNotBlank() -> ToolStatus.FAILED
            state in running -> ToolStatus.RUNNING
            state in completed || (state.isEmpty() && part.has_output) -> ToolStatus.COMPLETED
            else -> ToolStatus.OTHER
        }
    }

    fun isRunning(part: MessagePart): Boolean = part.state.lowercase() in running && !part.has_output && part.error_text.isEmpty()

    /** "read file" for `tool-read_file`; "Tool" when unnamed. */
    fun displayName(part: MessagePart): String =
        Parts.toolName(part).replace('_', ' ').replace('-', ' ').trim().ifEmpty { "Tool" }

    /** The tool's short title: after `__`, underscores as spaces. */
    fun title(name: String): String = compact(name.substringAfterLast("__").replace('_', ' ')).ifEmpty { "tool" }

    /** A one-line preview: the input, else (unless failed) the output, at most 140 characters. */
    fun preview(part: MessagePart): String {
        val input = part.input_preview.ifEmpty { part.input_json.utf8().trim().replace(Regex("\\s+"), " ") }
        val text = input.ifEmpty { if (status(part) == ToolStatus.FAILED) "" else part.output_preview }
        return if (text.length > 140) text.take(137) + "…" else text
    }

    /** The live description of a running tool, from its arguments. */
    fun activity(name: String, inputJson: String, inputPreview: String = ""): ToolActivity {
        val raw = inputJson.ifEmpty { inputPreview }
        val fields = if (raw.encodeToByteArray().size <= 16_384) parseFields(raw) else null
        val title = title(name)
        fields?.get("description")?.takeIf { it.isNotBlank() }?.let { return ToolActivity(ToolAction.DESCRIBED, compact(it), title) }
        val kind = kind(name)
        val (action, keys) = when (kind) {
            "read", "read_file", "readfile" -> ToolAction.READING to listOf("path", "file_path", "filePath")
            "edit", "write", "write_file", "edit_file", "multiedit", "multi_edit", "apply_patch", "patch" -> ToolAction.EDITING to listOf("path", "file_path", "filePath")
            "bash", "shell", "command", "exec", "exec_command", "terminal" -> ToolAction.RUNNING to listOf("command", "cmd", "argv")
            "grep", "glob", "search", "websearch", "web_search" -> ToolAction.SEARCHING to listOf("query", "pattern")
            "webfetch", "web_fetch", "fetch" -> ToolAction.FETCHING to listOf("url")
            "write_stdin", "wait" -> return ToolActivity(ToolAction.WAITING_FOR_COMMAND, null, title)
            else -> return ToolActivity(ToolAction.USING, null, title)
        }
        var target = keys.firstNotNullOfOrNull { fields?.get(it)?.takeIf { value -> value.isNotBlank() } }
        if (fields == null && raw.isNotBlank() && !raw.trimStart().let { it.startsWith("{") || it.startsWith("[") || it.startsWith("*** Begin Patch") }) target = raw
        if (target != null && (action == ToolAction.READING || action == ToolAction.EDITING)) target = target.trimEnd('/').substringAfterLast('/')
        return ToolActivity(action, target?.let(::compact)?.ifEmpty { null }, title)
    }

    /** Top-level string fields; string arrays join with spaces. */
    private fun parseFields(raw: String): Map<String, String>? {
        val json = runCatching { Json.parseToJsonElement(raw) as? JsonObject }.getOrNull() ?: return null
        return json.mapNotNull { (key, value) ->
            when (value) {
                is JsonPrimitive -> if (value.isString) key to value.content else null
                is JsonArray -> value.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.takeIf { it.isNotEmpty() }?.let { key to it.joinToString(" ") }
                else -> null
            }
        }.toMap()
    }

    /** First 1,024 characters, whitespace collapsed, at most 120. */
    fun compact(text: String): String {
        val collapsed = text.take(1024).replace(Regex("\\s+"), " ").trim()
        return if (collapsed.length > 120) collapsed.take(119) + "…" else collapsed
    }
}
