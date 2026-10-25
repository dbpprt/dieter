package com.getdieter.core.channels

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.KVEntry
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.SetChannelSettingRequest
import com.getdieter.client.v1.ChannelSettingChange
import com.getdieter.client.v1.ChannelSettingMode
import com.getdieter.client.v1.ChannelSettingOption
import com.getdieter.client.v1.ChannelSettingRow
import com.getdieter.client.v1.ChannelSettingScope
import com.getdieter.client.v1.ChannelSettingsSlice
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * The account's agent channel switches, as the replicated KV namespace `experimental` keeps them:
 * the global switch and project and board overrides (true is on, false is off, absent inherits).
 */
data class ChannelSwitches(
    val global: Boolean = false,
    val projects: Map<String, Boolean> = emptyMap(),
    val boards: Map<String, Boolean> = emptyMap(),
) {
    /**
     * A card's setting, as the daemon resolves it: the board's override, else the project's, else
     * the global switch. Chats have no board.
     */
    fun enabled(projectId: String, boardId: String? = null): Boolean {
        if (!boardId.isNullOrEmpty())
            boards[boardId]?.let {
                return it
            }
        return projects[projectId] ?: global
    }

    /** A project channel is in use: its own setting is on, or one of [boardIds] switches it on. */
    fun projectEnabled(projectId: String, boardIds: Collection<String>): Boolean =
        enabled(projectId) || boardIds.any { boards[it] == true }

    /** Some project or board may have channels on. */
    val anyEnabled: Boolean
        get() = global || projects.values.any { it } || boards.values.any { it }

    /** The mode of [scope]'s [id]; the global switch is never INHERIT. */
    fun mode(scope: ChannelSettingScope, id: String): ChannelSettingMode {
        val value =
            when (scope) {
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL -> global
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT -> projects[id]
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_BOARD -> boards[id]
                else -> null
            }
        return when (value) {
            null -> ChannelSettingMode.CHANNEL_SETTING_MODE_INHERIT
            true -> ChannelSettingMode.CHANNEL_SETTING_MODE_ON
            false -> ChannelSettingMode.CHANNEL_SETTING_MODE_OFF
        }
    }

    /** These switches with [change] applied. */
    fun with(change: ChannelSettingChange): ChannelSwitches {
        val on =
            when (change.mode) {
                ChannelSettingMode.CHANNEL_SETTING_MODE_ON -> true
                ChannelSettingMode.CHANNEL_SETTING_MODE_OFF -> false
                else -> null
            }
        return when (change.scope) {
            ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL -> copy(global = on ?: global)
            ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT ->
                copy(projects = projects.override(change.id, on))
            ChannelSettingScope.CHANNEL_SETTING_SCOPE_BOARD ->
                copy(boards = boards.override(change.id, on))
            else -> this
        }
    }

    /** [change] is what these switches already say. */
    fun shows(change: ChannelSettingChange): Boolean = mode(change.scope, change.id) == change.mode

    private fun Map<String, Boolean>.override(id: String, on: Boolean?): Map<String, Boolean> =
        if (on == null) this - id else this + (id to on)

    companion object {
        const val NAMESPACE = "experimental"
        const val GLOBAL_KEY = "channels"
        const val PROJECT_PREFIX = "channels.project."
        const val BOARD_PREFIX = "channels.board."

        /**
         * The switches the namespace's joined [entries] hold. The global value is a JSON boolean;
         * overrides are the JSON strings "on" and "off". Deleted and malformed entries inherit.
         */
        fun parse(entries: Map<String, KVEntry>): ChannelSwitches {
            var global = false
            val projects = mutableMapOf<String, Boolean>()
            val boards = mutableMapOf<String, Boolean>()
            for ((key, entry) in entries) {
                if (entry.deleted || entry.value_json.size == 0) continue
                val value =
                    runCatching {
                        Json.parseToJsonElement(entry.value_json.utf8()) as? JsonPrimitive
                    }
                        .getOrNull() ?: continue
                when {
                    key == GLOBAL_KEY -> global = value.booleanOrNull ?: global
                    key.startsWith(PROJECT_PREFIX) ->
                        override(value)?.let { projects[key.removePrefix(PROJECT_PREFIX)] = it }
                    key.startsWith(BOARD_PREFIX) ->
                        override(value)?.let { boards[key.removePrefix(BOARD_PREFIX)] = it }
                }
            }
            return ChannelSwitches(global, projects, boards)
        }

        private fun override(value: JsonPrimitive): Boolean? =
            if (!value.isString) null
            else
                when (value.content) {
                    "on" -> true
                    "off" -> false
                    else -> null
                }
    }
}

/** How the settings page, the project sheet and the board sheet word the switches. */
object ChannelSettingRules {
    private fun onOff(on: Boolean) = if (on) "On" else "Off"

    /** "Inherit (On)", "On" or "Off". */
    fun label(mode: ChannelSettingMode, inherited: Boolean): String =
        when (mode) {
            ChannelSettingMode.CHANNEL_SETTING_MODE_ON -> "On"
            ChannelSettingMode.CHANNEL_SETTING_MODE_OFF -> "Off"
            else -> "Inherit (${onOff(inherited)})"
        }

    fun options(inherited: Boolean): List<ChannelSettingOption> =
        listOf(
                ChannelSettingMode.CHANNEL_SETTING_MODE_INHERIT,
                ChannelSettingMode.CHANNEL_SETTING_MODE_ON,
                ChannelSettingMode.CHANNEL_SETTING_MODE_OFF,
            )
            .map { ChannelSettingOption(mode = it, label = label(it, inherited)) }

    /** A project's row: its override over the global switch. */
    fun project(project: Project, switches: ChannelSwitches): ChannelSettingRow {
        val mode = switches.mode(ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT, project.id)
        val inherited = switches.global
        return ChannelSettingRow(
            id = project.id,
            name = project.name,
            project_id = project.id,
            mode = mode,
            effective = switches.enabled(project.id),
            label = label(mode, inherited),
            options = options(inherited),
            detail =
                if (mode == ChannelSettingMode.CHANNEL_SETTING_MODE_INHERIT)
                    "Follows the global setting (${onOff(inherited)})."
                else "Overrides the global setting (${onOff(inherited)}) for this project.",
        )
    }

    /** A board's row: its override over its project's setting. */
    fun board(board: Board, switches: ChannelSwitches): ChannelSettingRow {
        val mode = switches.mode(ChannelSettingScope.CHANNEL_SETTING_SCOPE_BOARD, board.id)
        val inherited = switches.enabled(board.project_id)
        val source =
            if (switches.projects.containsKey(board.project_id)) "the project"
            else "the global setting"
        return ChannelSettingRow(
            id = board.id,
            name = board.name,
            project_id = board.project_id,
            mode = mode,
            effective = switches.enabled(board.project_id, board.id),
            label = label(mode, inherited),
            options = options(inherited),
            detail =
                if (mode == ChannelSettingMode.CHANNEL_SETTING_MODE_INHERIT)
                    "Follows $source (${onOff(inherited)})."
                else "Overrides $source (${onOff(inherited)}) for this board's agents.",
        )
    }

    fun slice(
        switches: ChannelSwitches,
        projects: List<Project>,
        boards: List<Board>,
        saving: Boolean = false,
        error: String? = null,
    ): ChannelSettingsSlice {
        val names = projects.associate { it.id to it.name.lowercase() }
        return ChannelSettingsSlice(
            global = switches.global,
            projects =
                projects.sortedWith(compareBy({ it.name.lowercase() }, { it.id })).map {
                    project(it, switches)
                },
            boards =
                boards
                    .sortedWith(
                        compareBy(
                            { names[it.project_id].orEmpty() },
                            { it.name.lowercase() },
                            { it.id },
                        )
                    )
                    .map { board(it, switches) },
            saving = saving,
            error = error.orEmpty(),
        )
    }

    /** The daemon's request for [change], after checking it. */
    fun request(change: ChannelSettingChange): SetChannelSettingRequest {
        val global = change.scope == ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL
        val scope =
            when (change.scope) {
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_GLOBAL -> "global"
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_PROJECT -> "project"
                ChannelSettingScope.CHANNEL_SETTING_SCOPE_BOARD -> "board"
                else -> invalidSetting("Choose what the setting applies to.")
            }
        if (!global && change.id.isBlank()) invalidSetting("Choose a project or board.")
        val value =
            when (change.mode) {
                ChannelSettingMode.CHANNEL_SETTING_MODE_ON -> "on"
                ChannelSettingMode.CHANNEL_SETTING_MODE_OFF -> "off"
                else ->
                    if (global) invalidSetting("The global setting is on or off.") else "inherit"
            }
        return SetChannelSettingRequest(
            scope = scope,
            id = if (global) "" else change.id,
            value_ = value,
        )
    }

    private fun invalidSetting(message: String): Nothing =
        throw CoreException(FailureKind.PERMANENT, message)
}

/** What the settings show: the account's switches with this device's unconfirmed changes. */
data class ChannelSettingsView(
    val switches: ChannelSwitches = ChannelSwitches(),
    val saving: Boolean = false,
    val error: String? = null,
)

/**
 * The agent channel settings: read from the account view's KV, written with SetChannelSetting on a
 * reachable machine (this device's first that accepts it), which replicates them. A change shows at
 * once and stays shown until the account view has it or the write fails. [send] performs one
 * SetChannelSetting call on a machine. Confined to the core dispatcher.
 */
class ChannelSettingsStore(
    private val send: suspend (daemonId: String, request: SetChannelSettingRequest) -> Unit,
    private val reachable: () -> List<String>,
    private val logger: CoreLogger,
) {
    constructor(
        sessions: MachineSessions,
        reachable: () -> List<String>,
        logger: CoreLogger,
    ) : this(
        { daemonId, request ->
            sessions.call(daemonId, Deadlines.CALL) { it.SetChannelSetting().execute(request) }
        },
        reachable,
        logger,
    )

    private var confirmed = ChannelSwitches()
    private var pending = emptyList<ChannelSettingChange>()
    private var writing = 0
    private var error: String? = null
    private val mutableView = MutableStateFlow(ChannelSettingsView())
    val view: StateFlow<ChannelSettingsView> = mutableView.asStateFlow()

    /** The account view's entries of the `experimental` namespace. */
    fun apply(entries: Map<String, KVEntry>) {
        confirmed = ChannelSwitches.parse(entries)
        pending = pending.filterNot(confirmed::shows)
        publish()
    }

    /** Forgets the previous account's unconfirmed changes. */
    fun reset() {
        pending = emptyList()
        error = null
        publish()
    }

    suspend fun set(change: ChannelSettingChange) {
        val request = ChannelSettingRules.request(change)
        pending = pending.filterNot { it.scope == change.scope && it.id == change.id } + change
        writing++
        error = null
        publish()
        try {
            write(request)
        } catch (failure: Throwable) {
            pending = pending - change
            if (failure !is CancellationException) error = Failures.message(failure)
            throw failure
        } finally {
            writing--
            publish()
        }
    }

    /**
     * Saves on the first reachable machine that accepts the change; the setting replicates from
     * there. A machine that fails (one this device does not trust, for example) is skipped, so it
     * cannot keep the others from saving. When none saves, the last failure shows.
     */
    private suspend fun write(request: SetChannelSettingRequest) {
        val machines = reachable()
        if (machines.isEmpty())
            throw CoreException(
                FailureKind.TRANSIENT,
                "No machine is reachable to save the setting.",
            )
        var failure: Throwable? = null
        for (machine in machines) {
            try {
                send(machine, request)
                return
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.info(
                    "Channels",
                    "$machine did not save the setting: ${Failures.message(error)}",
                )
                failure = error
            }
        }
        throw failure!!
    }

    private fun publish() {
        mutableView.value =
            ChannelSettingsView(
                switches = pending.fold(confirmed) { switches, change -> switches.with(change) },
                saving = writing > 0,
                error = error,
            )
    }
}
