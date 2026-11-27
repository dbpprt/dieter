package com.getdieter.core.reviews

import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.UiMessage
import com.getdieter.client.v1.TimelineCodeReview
import com.getdieter.client.v1.TimelineCodeReviewFinding
import com.getdieter.core.presentation.Counts
import com.getdieter.core.presentation.Parts
import com.getdieter.core.presentation.TokenCounts
import com.getdieter.core.presentation.Tools
import com.getdieter.core.runtime.Timestamps
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Code reviews in a conversation's transcript. A review is a `data-code-review` part whose
 * `data_json` is the JSON form of dieter.v1.CodeReview, replaced in place (same ID) when it goes
 * from running to its final status. An agent's review sits in its turn's assistant message right
 * after the agent's `request_code_review` tool call, which the review then stands for; a review the
 * user started has an assistant message of its own.
 */
object CodeReviews {
    const val PART_TYPE = "data-code-review"

    /** The agent's tool, whatever prefix its harness gives it ([Tools.kind]). */
    const val REQUEST_TOOL = "request_code_review"

    const val RUNNING = "running"
    const val COMPLETED = "completed"
    const val FAILED = "failed"
    const val CANCELLED = "cancelled"

    const val TRIGGER_AGENT = "agent"
    const val TRIGGER_USER = "user"

    fun isCodeReview(part: MessagePart): Boolean = part.type == PART_TYPE

    /** The agent's `request_code_review` tool call. */
    fun isRequest(part: MessagePart): Boolean =
        Parts.isToolCall(part) && Tools.kind(Parts.toolName(part)) == REQUEST_TOOL

    /**
     * The tool calls of [message] that a review of the same message answers; their tool rows are
     * left out because the review card represents them. A call without its review keeps its row.
     */
    fun answeredCalls(message: UiMessage): Set<String> =
        message.parts.filter(::isCodeReview).mapNotNullTo(HashSet()) { part ->
            payload(part)?.string("toolCallId")?.ifEmpty { null }
        }

    /**
     * [part]'s review laid out for the transcript, with harness names from [harnessName] (else the
     * harness ID); null when its payload is missing, unreadable or has no ID.
     */
    fun review(
        part: MessagePart,
        harnessName: (String) -> String? = { null },
    ): TimelineCodeReview? {
        val json = payload(part) ?: return null
        val id = json.string("id")
        if (id.isEmpty()) return null
        val status = json.string("status").lowercase().ifEmpty { RUNNING }
        val running = status == RUNNING
        val findings = sorted(json.findings("findings"))
        val resolved = json.findings("resolved")
        val harness = json.string("harness")
        val filesChanged = json.int("filesChanged")
        return TimelineCodeReview(
            review_id = id,
            status = status,
            running = running,
            title = title(status),
            subtitle =
                subtitle(
                    harness
                        .ifEmpty { null }
                        ?.let { harnessName(it)?.ifEmpty { null } ?: it }
                        .orEmpty(),
                    json.string("model"),
                    json.string("depth"),
                    if (running) 0 else json.long("durationMs"),
                    json.long("inputTokens") + json.long("outputTokens"),
                ),
            counts_label = countsLabel(status, findings, filesChanged),
            round_label = roundLabel(json.int("round"), findings, resolved),
            trigger_label = triggerLabel(json.string("trigger")),
            summary = json.string("summary").trim(),
            security = security(json.string("security")),
            error =
                if (status == FAILED || status == CANCELLED) json.string("error").trim() else "",
            findings = findings,
            resolved = resolved,
            highest_severity = findings.firstOrNull()?.severity.orEmpty(),
            started_at_millis =
                Timestamps.parse(json.string("startedAt"))?.toEpochMilliseconds() ?: 0,
            finished_at_millis =
                Timestamps.parse(json.string("finishedAt"))?.toEpochMilliseconds() ?: 0,
            change_label = changeLabel(filesChanged, json.int("additions"), json.int("deletions")),
            card_id = json.string("cardId"),
        )
    }

    /** "Code review", "Reviewing changes…", "Code review failed", "Code review cancelled". */
    fun title(status: String): String =
        when (status) {
            RUNNING -> "Reviewing changes…"
            FAILED -> "Code review failed"
            CANCELLED -> "Code review cancelled"
            else -> "Code review"
        }

    /**
     * "Claude Code · opus · quick · 42 s · 224k tokens"; unknown parts are left out, and so are the
     * duration and tokens while they are zero.
     */
    fun subtitle(
        harness: String,
        model: String,
        depth: String,
        durationMs: Long,
        tokens: Long,
    ): String =
        listOf(
                harness,
                model,
                depth,
                duration(durationMs),
                if (tokens > 0) "${TokenCounts.compact(tokens)} tokens" else "",
            )
            .filter { it.isNotBlank() }
            .joinToString(" · ")

    /** "42 s", "3 min 12 s", "5 min"; empty for no time. */
    fun duration(durationMs: Long): String {
        val seconds = durationMs / 1000
        if (durationMs <= 0) return ""
        if (seconds < 60) return "${seconds.coerceAtLeast(1)} s"
        val minutes = seconds / 60
        val rest = seconds % 60
        return if (rest == 0L) "$minutes min" else "$minutes min $rest s"
    }

    /**
     * "4 findings · 2 high", "1 finding", "No findings", "No changes to review" for a completed
     * review; empty while it runs or after it failed.
     */
    fun countsLabel(
        status: String,
        findings: List<TimelineCodeReviewFinding>,
        filesChanged: Int,
    ): String {
        if (status != COMPLETED) return ""
        if (findings.isEmpty())
            return if (filesChanged == 0) "No changes to review" else "No findings"
        val high = findings.count { it.severity == HIGH }
        val total = Counts.of(findings.size, "finding")
        return if (high > 0 && findings.size > 1) "$total · $high high" else total
    }

    /**
     * "Round 2 · 2 resolved · 1 still open · 1 new": a later round against the previous review;
     * empty for the first.
     */
    fun roundLabel(
        round: Int,
        findings: List<TimelineCodeReviewFinding>,
        resolved: List<TimelineCodeReviewFinding>,
    ): String {
        if (round <= 1) return ""
        val open = findings.count { it.status == OPEN }
        val new = findings.count { it.status == NEW }
        return listOfNotNull(
                "Round $round",
                resolved.size.takeIf { it > 0 }?.let { "$it resolved" },
                open.takeIf { it > 0 }?.let { "$it still open" },
                new.takeIf { it > 0 }?.let { "$it new" },
            )
            .joinToString(" · ")
    }

    fun triggerLabel(trigger: String): String =
        when (trigger) {
            TRIGGER_AGENT -> "Requested by the agent"
            TRIGGER_USER -> "Requested by you"
            else -> ""
        }

    /** "12 files · +340 −41"; empty when the review read no change. */
    fun changeLabel(files: Int, additions: Int, deletions: Int): String =
        if (files <= 0) "" else "${Counts.of(files, "file")} · +$additions −$deletions"

    /** "internal/git/unborn.go:23–26", "README.md:4", or the bare path without lines. */
    fun location(file: String, startLine: Int, endLine: Int): String =
        when {
            file.isEmpty() -> ""
            startLine <= 0 -> file
            endLine > startLine -> "$file:$startLine–$endLine"
            else -> "$file:$startLine"
        }

    fun severityLabel(severity: String): String =
        when (severity) {
            HIGH -> "High"
            MEDIUM -> "Medium"
            LOW -> "Low"
            else -> severity.replaceFirstChar { it.uppercaseChar() }
        }

    fun statusLabel(status: String): String =
        when (status) {
            NEW -> "New"
            OPEN -> "Still open"
            RESOLVED -> "Resolved"
            else -> status.replaceFirstChar { it.uppercaseChar() }
        }

    /** The reviewer's security concern; empty for "No" and the like. */
    fun security(value: String): String {
        val text = value.trim()
        return if (text.trimEnd('.').lowercase() in NONE) "" else text
    }

    private const val HIGH = "high"
    private const val MEDIUM = "medium"
    private const val LOW = "low"
    private const val NEW = "new"
    private const val OPEN = "open"
    private const val RESOLVED = "resolved"
    private val NONE = setOf("", "no", "none", "n/a")

    /** Most severe first, keeping the reviewer's order within a severity. */
    private fun sorted(findings: List<TimelineCodeReviewFinding>) = findings.sortedBy {
        when (it.severity) {
            HIGH -> 0
            MEDIUM -> 1
            LOW -> 2
            else -> 3
        }
    }

    private fun payload(part: MessagePart): JsonObject? {
        if (!isCodeReview(part) || part.data_json.size == 0) return null
        return runCatching { Json.parseToJsonElement(part.data_json.utf8()) as? JsonObject }
            .getOrNull()
    }

    private fun JsonObject.findings(key: String): List<TimelineCodeReviewFinding> =
        (get(key) as? JsonArray).orEmpty().mapNotNull { element ->
            val finding = element as? JsonObject ?: return@mapNotNull null
            val file = finding.string("file")
            val start = finding.int("startLine")
            val end = finding.int("endLine")
            val severity = finding.string("severity").lowercase()
            val status = finding.string("status").lowercase()
            TimelineCodeReviewFinding(
                id = finding.string("id"),
                file_ = file,
                start_line = start,
                end_line = end,
                location_label = location(file, start, end),
                severity = severity,
                severity_label = severityLabel(severity),
                confidence = finding.int("confidence"),
                title = finding.string("title").trim(),
                body = finding.string("body").trim(),
                suggestion = finding.string("suggestion").trim(),
                status = status,
                status_label = statusLabel(status),
            )
        }

    private fun JsonObject.string(key: String): String =
        (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()

    private fun JsonObject.long(key: String): Long =
        (get(key) as? JsonPrimitive)?.content?.let {
            it.toLongOrNull() ?: it.toDoubleOrNull()?.toLong()
        } ?: 0

    private fun JsonObject.int(key: String): Int =
        long(key).coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()
}
