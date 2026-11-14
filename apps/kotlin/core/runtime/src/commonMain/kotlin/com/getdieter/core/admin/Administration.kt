package com.getdieter.core.admin

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.PeerVersion
import com.getdieter.api.v1.Project
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.workspace.ValidationCommandDraft
import kotlin.random.Random
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive

/**
 * Projects, checkouts, boards, labels, prompt settings, conversations' workspaces, and
 * shared-record conflicts, each on the machine [MachineChoice] picks for it. Each part routes its
 * calls through one [AdminCalls], which keeps the operation IDs of pending intents. Confined to the
 * core dispatcher.
 */
class Administration(sessions: MachineSessions, store: WorkspaceStore, choice: MachineChoice) {
    private val calls = AdminCalls(sessions, store, choice)
    val projects = ProjectAdmin(calls, sessions, store, choice)
    val boards = BoardAdmin(calls, store)
    val prompts = PromptAdmin(calls, store)
    val conversations = ConversationAdmin(calls, store)
    val conflicts = ConflictAdmin(calls)

    /** Intents whose operation ID is kept for a retry (observed by the :core:e2e tests). */
    val pendingIntents: Int
        get() = calls.pendingIntents
}

/**
 * What the project and board forms offer, start with, and require, worded once for every client.
 */
object AdminForms {
    val ARCHIVE_POLICIES =
        listOf(
            "never",
            "immediately",
            "after_1_day",
            "after_7_days",
            "after_30_days",
            "after_90_days",
        )
    val PUBLISH_MODES = listOf("manual", "pull_request", "push_base")

    /**
     * A board with a review lane, or one that moves finished work straight to Done; review first.
     */
    val WORKFLOWS = listOf("review", "direct")

    /** What a new project or board starts with unless the user changes it. */
    const val DEFAULT_BOARD_NAME = "Main"
    const val DEFAULT_WORKFLOW = "review"
    const val DEFAULT_BASE_REMOTE = "origin"
    const val DEFAULT_BASE_BRANCH = "main"
    const val DEFAULT_PUBLISH_MODE = "manual"
    const val DEFAULT_ARCHIVE_POLICY = "never"

    /** "Never", "Immediately", "After 7 days". */
    fun archivePolicyTitle(policy: String): String =
        policy.replace('_', ' ').replaceFirstChar { it.uppercase() }

    fun publishModeTitle(mode: String): String =
        when (mode) {
            "manual" -> "Manual"
            "pull_request" -> "Pull request"
            "push_base" -> "Push base branch"
            else -> mode
        }

    /** What a publish mode does with a conversation's finished branch. */
    fun publishModeDetail(mode: String): String =
        when (mode) {
            "manual" -> "Choose local merge, branch push, or pull request when publishing."
            "pull_request" -> "Publish the conversation branch through a pull request."
            "push_base" -> "Push the validated integration result directly to the base branch."
            else -> ""
        }

    /** "With review" or "Direct to done"; an unknown workflow reads as itself. */
    fun workflowTitle(workflow: String): String =
        when (workflow) {
            "review" -> "With review"
            "direct" -> "Direct to done"
            else -> workflow
        }

    /**
     * The lanes a workflow's cards pass: "Todo → Running → Review → Done", or without Review for
     * direct.
     */
    fun workflowLanes(workflow: String): String =
        if (workflow == "direct") "Todo → Running → Done" else "Todo → Running → Review → Done"

    /** What a workflow does with finished agent work. */
    fun workflowDetail(workflow: String): String =
        if (workflow == "direct") "Direct moves completed work straight to Done."
        else "Review keeps completed agent work waiting for your approval."

    /** The remote a project's workspaces branch from, [DEFAULT_BASE_REMOTE] when unset. */
    fun baseRemote(project: Project): String = project.base_remote.ifBlank { DEFAULT_BASE_REMOTE }

    /** The branch a project's workspaces start from, [DEFAULT_BASE_BRANCH] when unset. */
    fun baseBranch(project: Project): String = project.base_branch.ifBlank { DEFAULT_BASE_BRANCH }

    /** The remote a board's workspaces publish to: its own, else its project's. */
    fun boardRemote(board: Board, project: Project?): String =
        board.base_remote.ifBlank { project?.base_remote.orEmpty() }

    /** How a board publishes finished work, [DEFAULT_PUBLISH_MODE] when unset. */
    fun publishMode(board: Board): String =
        board.remote_publish_mode.ifBlank { DEFAULT_PUBLISH_MODE }

    /**
     * A new project needs a folder, a base branch, and valid validation commands; a blank board
     * name becomes [DEFAULT_BOARD_NAME].
     */
    fun canCreateProject(
        path: String,
        baseBranch: String,
        validation: List<ValidationCommandDraft>,
    ): Boolean =
        path.isNotBlank() &&
            baseBranch.isNotBlank() &&
            ValidationCommandDraft.problem(validation) == null

    /**
     * The project settings form saves with a name, a base branch, and valid validation commands.
     */
    fun canSaveProject(
        name: String,
        baseBranch: String,
        validation: List<ValidationCommandDraft>,
    ): Boolean =
        name.isNotBlank() &&
            baseBranch.isNotBlank() &&
            ValidationCommandDraft.problem(validation) == null
}

data class LabelColor(val name: String, val value: String)

object Labels {
    /** The palette every client offers, by name. */
    val COLORS =
        listOf(
            LabelColor("Ruby", "#d95c68"),
            LabelColor("Coral", "#df7650"),
            LabelColor("Amber", "#c9952f"),
            LabelColor("Lime", "#7d9e45"),
            LabelColor("Emerald", "#3e9970"),
            LabelColor("Teal", "#379799"),
            LabelColor("Sky", "#478dc5"),
            LabelColor("Indigo", "#626fd0"),
            LabelColor("Violet", "#8a62c3"),
            LabelColor("Rose", "#c65f98"),
        )
    val PALETTE = COLORS.map { it.value }
    private val hex = Regex("^#[0-9a-fA-F]{6}$")

    fun validate(name: String, color: String): String? =
        when {
            name.isBlank() -> "label name is required"
            color.isNotBlank() && !hex.matches(color.trim()) ->
                "label color must be a hex color such as #6558df"
            else -> null
        }

    /** A palette color other than [exclude]. */
    fun randomColor(exclude: String? = null, random: Random = Random): String =
        PALETTE.filterNot { it.equals(exclude, ignoreCase = true) }.random(random)

    /** [color]'s palette entry, else the first. */
    fun named(color: String): LabelColor =
        COLORS.firstOrNull { it.value.equals(color, ignoreCase = true) } ?: COLORS.first()

    /** The same palette color for [id] on every launch and client. */
    fun stable(id: String): String = PALETTE[id.hashCode().mod(PALETTE.size)]
}

/** How competing versions of a shared record read when the user picks one. */
object ConflictVersions {
    /** A string value as itself, other JSON compactly, a deletion as "Deleted". */
    fun versionText(version: PeerVersion): String {
        if (version.deleted) return "Deleted"
        val raw = version.value_json.utf8()
        val element = runCatching { Json.parseToJsonElement(raw) }.getOrNull() ?: return raw
        return (element as? JsonPrimitive)?.takeIf { it.isString }?.content ?: element.toString()
    }

    fun keepLabel(version: PeerVersion): String =
        if (version.deleted) "Keep deletion" else "Keep this value"
}

/** Browser hostnames that route captured tasks to a project or board. */
object Hostnames {
    const val MAX = 64

    /**
     * Lowercase `host` or `host:port` values, deduplicated and sorted; rejects URLs, paths, and
     * wildcards.
     */
    fun normalize(values: List<String>): Result<List<String>> {
        val normalized = mutableSetOf<String>()
        for (raw in values) {
            val value = raw.trim()
            if (value.isEmpty()) continue
            val host: String
            val port: Int?
            when {
                value.startsWith("[") -> {
                    val end = value.indexOf(']')
                    if (end < 0) return invalid(value)
                    host = value.substring(1, end)
                    val rest = value.substring(end + 1)
                    port =
                        if (rest.isEmpty()) null
                        else rest.removePrefix(":").toIntOrNull() ?: return invalid(value)
                    if (':' !in host) return invalid(value)
                }
                value.count { it == ':' } == 1 -> {
                    host = value.substringBefore(':')
                    port = value.substringAfter(':').toIntOrNull() ?: return invalid(value)
                }
                value.count { it == ':' } > 1 -> {
                    host = value
                    port = null
                }
                else -> {
                    host = value
                    port = null
                }
            }
            val name = host.lowercase().trimEnd('.')
            if (
                name.isEmpty() ||
                    name.any {
                        it == '/' ||
                            it == '*' ||
                            it == '?' ||
                            it == '#' ||
                            it == '@' ||
                            it.isWhitespace()
                    }
            )
                return invalid(value)
            if (port != null && port !in 1..65535) return invalid(value)
            normalized +=
                when {
                    port == null -> name
                    ':' in name -> "[$name]:$port"
                    else -> "$name:$port"
                }
        }
        if (normalized.size > MAX)
            return Result.failure(
                IllegalArgumentException("at most 64 project hostnames are allowed")
            )
        return Result.success(normalized.sorted())
    }

    private fun invalid(value: String) =
        Result.failure<List<String>>(
            IllegalArgumentException(
                "invalid project hostname \"$value\": use host or host:port (1-65535), with IPv6 ports written as [::1]:4018; no URL, path, or wildcard"
            )
        )
}

/**
 * Client-side checks mirroring the daemon's prompt template validation, for live editor feedback.
 */
object PromptTemplates {
    const val MAX_BYTES = 32 * 1024
    val VARIABLES =
        listOf(
            "scope",
            "project.name",
            "project.id",
            "project.path",
            "project.registered_path",
            "project.summary",
            "project.instructions",
            "project.instructions_block",
            "workspace.path",
            "workspace.mode",
            "workspace.branch",
            "workspace.base_branch",
            "workspace.base_remote",
            "workspace.base_sha",
            "workspace.remote_publish_mode",
            "board.name",
            "board.id",
            "board.workflow",
            "board.description",
            "board.labels",
            "board.target_lane",
            "card.id",
            "card.title",
            "card.lane",
            "card.labels",
            "labels.instructions",
            "labels.instructions_block",
        )
    private val placeholder = Regex("\\{\\{\\s*([a-z0-9_.]+)\\s*\\}\\}")

    /**
     * The first problem with [template], or null; context templates must place both instruction
     * blocks once.
     */
    fun validate(template: String, context: Boolean = false): String? {
        if (template.isBlank()) return "template is required"
        if (template.encodeToByteArray().size > MAX_BYTES) return "template exceeds 32 KiB"
        val names = placeholder.findAll(template).map { it.groupValues[1] }.toList()
        names
            .firstOrNull { it !in VARIABLES }
            ?.let {
                return "unknown template variable {{$it}}"
            }
        val rest = placeholder.replace(template, "")
        if ("{{" in rest || "}}" in rest) return "template contains a malformed variable"
        if (context) {
            for (required in listOf("project.instructions_block", "labels.instructions_block")) {
                if (names.count { it == required } != 1)
                    return "template must contain {{$required}} exactly once"
            }
        }
        return null
    }
}
