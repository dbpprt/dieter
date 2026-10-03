package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.CreateTerminalRequest
import com.dbpprt.dieter.api.v1.ListTerminalsRequest
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.RenameTerminalRequest
import com.dbpprt.dieter.api.v1.ResizeTerminalRequest
import com.dbpprt.dieter.api.v1.Terminal
import com.dbpprt.dieter.api.v1.TerminalFrame
import com.dbpprt.dieter.api.v1.TerminalRef
import com.dbpprt.dieter.api.v1.WatchTerminalRequest
import com.dbpprt.dieter.client.v1.TerminalRow
import com.dbpprt.dieter.client.v1.Tone
import com.dbpprt.dieter.core.presentation.Counts
import com.dbpprt.dieter.core.presentation.DisplayPaths
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.dbpprt.dieter.core.storage.CoreStorage
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

enum class TerminalScopeKind { MACHINE, PROJECT, CARD }

/** Which terminals a surface shows, on one machine. */
data class TerminalScope(val daemonId: String, val kind: TerminalScopeKind, val projectId: String = "", val checkoutId: String = "", val cardId: String = "") {
    val selectionKey: String get() = "$daemonId|$projectId|$cardId"

    companion object {
        /** Where a new terminal for [project] on [daemonId] lives: its checkout there, else the machine. */
        fun forCreation(daemonId: String, project: Project?): TerminalScope {
            val checkout = project?.checkouts?.firstOrNull { it.daemon_id == daemonId && !it.detached }
                ?: return TerminalScope(daemonId, TerminalScopeKind.MACHINE)
            return TerminalScope(daemonId, TerminalScopeKind.PROJECT, project.id, checkout.id)
        }

        /** The machine a new terminal starts on: the one [chosen] for the surface, else the [attached] one. */
        fun creationMachine(chosen: String?, attached: String?): String =
            chosen ?: attached ?: throw CoreException(FailureKind.TRANSIENT, "No machine is attached.")
    }
}

/** A running terminal takes input and resizes; an exited one only shows its scrollback. */
val Terminal.running: Boolean get() = status == "running"

/** The new-terminal form: a project, a name, a shell, and where it starts. */
data class NewTerminal(val projectId: String = "", val name: String = "", val shell: String = DEFAULT_SHELL, val workingDirectory: String = "") {
    val ready: Boolean get() = projectId.isNotBlank() && name.isNotBlank() && workingDirectory.isNotBlank()

    /** Another project starts in its own directory. */
    fun project(project: Project): NewTerminal = copy(projectId = project.id, workingDirectory = project.path)

    companion object {
        const val DEFAULT_SHELL = "zsh"
        val SHELLS = listOf("zsh", "bash", "fish", "sh")

        fun initial(project: Project?, name: String): NewTerminal = NewTerminal(project?.id.orEmpty(), name, DEFAULT_SHELL, project?.path.orEmpty())

        /** The project picker's choices: by name ignoring case, then by ID. */
        fun projects(projects: List<Project>): List<Project> = projects.sortedWith(compareBy<Project> { it.name.lowercase() }.thenBy { it.id })

        /** A project choice's detail: its machine (offline when known to be) and its compact path. */
        fun projectDetails(project: Project, hostName: String?, hostOnline: Boolean?): String {
            val machine = hostName?.takeIf(String::isNotBlank) ?: "Unknown machine"
            val availability = if (hostOnline == false) "$machine (offline)" else machine
            return listOfNotNull(availability, DisplayPaths.compact(project.path).takeIf(String::isNotBlank)).joinToString(" · ")
        }
    }
}

data class TerminalsView(
    val scope: TerminalScope? = null,
    val terminals: List<Terminal> = emptyList(),
    val selectedId: String? = null,
    val screens: Map<String, TerminalScreen> = emptyMap(),
    val loading: Boolean = false,
    val error: String? = null,
    val streamConnected: Boolean = false,
    val active: Boolean = false,
) {
    val selected: Terminal? get() = terminals.firstOrNull { it.id == selectedId }
    fun screen(id: String): TerminalScreen = screens[id] ?: TerminalScreen.EMPTY

    companion object {
        /** A terminal surface's status line: syncing while [loading], what terminals are while there are none, else "2 persistent sessions · live" or "· reconnecting". */
        fun status(loading: Boolean, count: Int, streamConnected: Boolean): String = when {
            loading -> "Syncing persistent sessions…"
            count == 0 -> "Daemon-owned · survive app disconnects"
            else -> "${Counts.of(count, "persistent session")} · ${if (streamConnected) "live" else "reconnecting"}"
        }

        /** The overview's status line: syncing while [loading], what terminals are while there are none, else "2 persistent sessions across 1 machine". */
        fun overviewStatus(loading: Boolean, count: Int, machines: Int): String = when {
            loading && count == 0 -> "Syncing persistent sessions…"
            count == 0 -> "Daemon-owned · survive app disconnects"
            else -> "${Counts.of(count, "persistent session")} across ${Counts.of(machines, "machine")}"
        }

        /**
         * One terminal's status: "Connected" or "Reconnecting" while it runs,
         * by whether its output streams; otherwise "Exited", with the
         * [exitCode] when the daemon reported one.
         */
        fun terminalStatus(status: String, exitCode: Int?, streamConnected: Boolean): String = when {
            status == "running" -> if (streamConnected) "Connected" else "Reconnecting"
            exitCode != null -> "Exited $exitCode"
            else -> "Exited"
        }

        /** A running, streaming terminal succeeds, a running one waiting for its stream warns, a failed exit is danger, a clean one neutral. */
        fun tone(terminal: Terminal, streamConnected: Boolean): Tone = when {
            terminal.running -> if (streamConnected) Tone.TONE_SUCCESS else Tone.TONE_WARNING
            terminal.exit_code?.let { it != 0 } == true -> Tone.TONE_DANGER
            else -> Tone.TONE_NEUTRAL
        }

        /** What closing [terminal] does, for its confirmation. */
        fun closeMessage(terminal: Terminal): String =
            if (terminal.running) "This explicitly ends the daemon-owned shell. Leaving this screen does not." else "This removes the finished session and its scrollback."

        /** How every client shows [terminal] beside the others. */
        fun row(terminal: Terminal, streamConnected: Boolean) = TerminalRow(
            id = terminal.id, running = terminal.running,
            status = terminalStatus(terminal.status, terminal.exit_code, streamConnected), tone = tone(terminal, streamConnected),
            accepts_input = terminal.running && streamConnected, close_message = closeMessage(terminal),
        )
    }
}

/**
 * The terminals of one surface (a machine, project, or conversation). Only
 * the selected terminal of an active surface streams; hiding it stops the
 * stream and never the shell. Resumes from the last delivered sequence.
 * Confined to the core dispatcher.
 */
class Terminals(
    private val sessions: MachineSessions,
    private val pumps: TerminalInputPumps,
    private val selections: TerminalSelections,
    private val scope: CoroutineScope,
) {
    private val mutableView = MutableStateFlow(TerminalsView())
    val view: StateFlow<TerminalsView> = mutableView.asStateFlow()
    private var epoch = 0L
    private var watch: Job? = null
    private var watchedId: String? = null
    private var resize: Job? = null
    private val cursors = HashMap<String, Long>()
    private val recent = ArrayDeque<String>()

    fun bind(target: TerminalScope?) {
        if (target == view.value.scope) return
        epoch++
        stopWatch()
        resize?.cancel()
        view.value.scope?.let { old -> view.value.terminals.forEach { pumps.cancel(TerminalKey(old.daemonId, it.id)) } }
        cursors.clear()
        recent.clear()
        mutableView.value = TerminalsView(scope = target, active = view.value.active)
    }

    /** Stops streaming and input when no view shows the surface any more; the shells keep running. */
    fun stop() {
        setActive(false)
        bind(null)
    }

    /** Foreground and visible: stream the selection. Otherwise only stop streaming. */
    fun setActive(active: Boolean) {
        mutableView.update { it.copy(active = active) }
        if (active) startWatch() else {
            stopWatch()
            resize?.cancel()
        }
    }

    suspend fun load() {
        val target = view.value.scope ?: return
        val bound = epoch
        mutableView.update { it.copy(loading = true) }
        try {
            val request = when (target.kind) {
                TerminalScopeKind.MACHINE -> ListTerminalsRequest()
                TerminalScopeKind.PROJECT -> ListTerminalsRequest(project_id = target.projectId, checkout_id = target.checkoutId)
                TerminalScopeKind.CARD -> ListTerminalsRequest(project_id = target.projectId, card_id = target.cardId)
            }
            val listed = sessions.call(target.daemonId, Deadlines.CALL) { it.ListTerminals().execute(request) }.terminals
            if (bound != epoch) return
            val terminals = listed.filter { target.kind != TerminalScopeKind.CARD || it.card_id == target.cardId }.sortedWith(ORDER)
            val ids = terminals.mapTo(HashSet()) { it.id }
            val current = view.value.selectedId?.takeIf { it in ids }
            val selected = current ?: selections.get(target.selectionKey)?.takeIf { it in ids } ?: terminals.firstOrNull()?.id
            cursors.keys.retainAll(ids)
            mutableView.update { it.copy(terminals = terminals, loading = false, error = null, screens = it.screens.filterKeys { id -> id in ids }) }
            select(selected)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == epoch) mutableView.update { it.copy(loading = false, error = Failures.message(error)) }
        }
    }

    fun select(id: String?) {
        val target = view.value.scope ?: return
        if (id == view.value.selectedId && (id == null || watchedId == id)) return
        stopWatch()
        mutableView.update { it.copy(selectedId = id) }
        selections.set(target.selectionKey, id)
        if (id != null) {
            recent.remove(id)
            recent.addLast(id)
            // Keep screens only for the most recently viewed terminals; evicted ones replay from the daemon.
            while (recent.size > MAX_SCREENS) {
                val evicted = recent.removeFirst()
                cursors.remove(evicted)
                mutableView.update { it.copy(screens = it.screens - evicted) }
            }
        }
        startWatch()
    }

    /** Creates a terminal in this scope and selects it. */
    suspend fun create(name: String = "", shell: String = "", workingDirectory: String? = null, columns: Int = 120, rows: Int = 36): Terminal {
        val target = view.value.scope ?: throw CoreException(FailureKind.PERMANENT, "Choose a machine first.")
        val bound = epoch
        val request = when (target.kind) {
            TerminalScopeKind.MACHINE -> CreateTerminalRequest(name = name, shell = shell, working_directory = workingDirectory.orEmpty(), columns = columns, rows = rows, machine_home = true)
            TerminalScopeKind.PROJECT -> CreateTerminalRequest(
                project_id = target.projectId, checkout_id = target.checkoutId, name = name, shell = shell,
                working_directory = workingDirectory.orEmpty(), columns = columns, rows = rows,
            )
            TerminalScopeKind.CARD -> CreateTerminalRequest(
                project_id = target.projectId, card_id = target.cardId, name = name, shell = shell,
                working_directory = workingDirectory ?: ".", columns = columns, rows = rows,
            )
        }
        val created = sessions.call(target.daemonId, Deadlines.CALL) { it.CreateTerminal().execute(request) }
        if (bound != epoch) return created
        cursors[created.id] = 0
        mutableView.update { it.copy(terminals = (it.terminals.filterNot { t -> t.id == created.id } + created).sortedWith(ORDER), screens = it.screens + (created.id to TerminalScreen.EMPTY)) }
        select(created.id)
        return created
    }

    suspend fun rename(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val target = view.value.scope ?: return
        val bound = epoch
        val renamed = sessions.call(target.daemonId, Deadlines.CALL) { it.RenameTerminal().execute(RenameTerminalRequest(terminal_id = id, name = trimmed)) }
        if (bound == epoch) upsert(renamed)
    }

    /** Ends the shell and forgets its scrollback. */
    suspend fun close(id: String) {
        val target = view.value.scope ?: return
        val bound = epoch
        sessions.call(target.daemonId, Deadlines.CALL) { it.CloseTerminal().execute(TerminalRef(terminal_id = id)) }
        if (bound == epoch) remove(id)
    }

    /** Sends input to the selected terminal; only a running terminal of an active surface accepts it. */
    fun input(bytes: ByteArray) {
        val state = view.value
        val target = state.scope ?: return
        val terminal = state.selected ?: return
        if (!state.active || !terminal.running) return
        pumps.send(TerminalKey(target.daemonId, terminal.id), bytes) { message -> mutableView.update { it.copy(error = message) } }
    }

    /** The visible grid changed; the daemon resizes 120 ms after the last change. */
    fun gridChanged(columns: Int, rows: Int) {
        val state = view.value
        val target = state.scope ?: return
        val terminal = state.selected ?: return
        if (!state.active || !terminal.running) return
        if (columns !in 2..500 || rows !in 2..500) return
        if (terminal.columns == columns && terminal.rows == rows) return
        resize?.cancel()
        val bound = epoch
        resize = scope.launch {
            delay(RESIZE_DEBOUNCE)
            try {
                val resized = sessions.call(target.daemonId, Deadlines.CALL) { it.ResizeTerminal().execute(ResizeTerminalRequest(terminal_id = terminal.id, columns = columns, rows = rows)) }
                if (bound == epoch) upsert(resized)
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
            }
        }
    }

    private fun startWatch() {
        val state = view.value
        val target = state.scope ?: return
        val id = state.selectedId ?: return
        if (!state.active || watchedId == id) return
        watchedId = id
        val bound = epoch
        watch = scope.launch {
            var attempt = 0
            while (bound == epoch && watchedId == id) {
                try {
                    coroutineScope {
                        sessions.call(target.daemonId) { client ->
                            val call = client.WatchTerminal()
                            val frames = call.executeIn(this, WatchTerminalRequest(terminal_id = id, after_sequence = cursors[id] ?: 0, heartbeat_ms = HEARTBEAT_MS))
                            try {
                                while (true) {
                                    // A stream that stops delivering, even heartbeats, is resumed from the cursor.
                                    val frame = withTimeoutOrNull(STALL) { frames.receiveCatching() } ?: break
                                    val received = frame.getOrNull() ?: break
                                    attempt = 0
                                    apply(id, received)
                                }
                            } finally {
                                call.cancel()
                            }
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (error is GrpcException && error.grpcStatus == GrpcStatus.NOT_FOUND) {
                        if (bound == epoch) remove(id)
                        return@launch
                    }
                }
                mutableView.update { it.copy(streamConnected = false) }
                delay(Backoff.TERMINAL.delay(attempt++))
            }
        }
    }

    private fun apply(id: String, frame: TerminalFrame) {
        frame.terminal?.takeIf { it.id == id }?.let(::upsert)
        // A heartbeat reports the current sequence, which may be ahead of undelivered data.
        if (!frame.heartbeat) cursors[id] = maxOf(cursors[id] ?: 0, frame.sequence)
        mutableView.update { state ->
            val screen = state.screen(id)
            val next = when {
                frame.screen_reset -> screen.reset(frame.data_)
                frame.data_.size > 0 -> screen.append(frame.data_)
                else -> null
            }
            state.copy(streamConnected = true, screens = if (next != null) state.screens + (id to next) else state.screens)
        }
    }

    private fun stopWatch() {
        watch?.cancel()
        watch = null
        watchedId = null
    }

    private fun upsert(terminal: Terminal) = mutableView.update { state ->
        state.copy(terminals = state.terminals.map { if (it.id == terminal.id) terminal else it })
    }

    private fun remove(id: String) {
        view.value.scope?.let { pumps.cancel(TerminalKey(it.daemonId, id)) }
        cursors.remove(id)
        recent.remove(id)
        val wasSelected = view.value.selectedId == id
        mutableView.update { it.copy(terminals = it.terminals.filterNot { t -> t.id == id }, screens = it.screens - id) }
        if (wasSelected) {
            stopWatch()
            mutableView.update { it.copy(selectedId = null) }
            select(view.value.terminals.firstOrNull()?.id)
        }
    }

    companion object {
        const val HEARTBEAT_MS = 15_000
        const val MAX_SCREENS = 4
        private val STALL = 35.seconds
        private val RESIZE_DEBOUNCE = 120.milliseconds
        private val ORDER = compareBy<Terminal>({ it.created_at }, { it.id })
    }
}

/**
 * Remembered terminal per surface, least recently used evicted beyond 64.
 * Each choice is stamped by a logical clock that resumes from the newest
 * stored stamp, so the order survives restarts.
 */
class TerminalSelections(private val storage: () -> CoreStorage?) {
    private var cache: MutableMap<String, Pair<String, Long>>? = null
    private var clock = 0L

    private fun entries(): MutableMap<String, Pair<String, Long>> = cache ?: load().also { loaded ->
        cache = loaded
        clock = maxOf(clock, loaded.values.maxOfOrNull { it.second } ?: 0L)
    }

    private fun load(): MutableMap<String, Pair<String, Long>> {
        val bytes = storage()?.read(FILE) ?: return LinkedHashMap()
        val json = runCatching { Json.parseToJsonElement(bytes.decodeToString()).jsonObject }.getOrNull() ?: return LinkedHashMap()
        return json.mapNotNull { (key, value) ->
            val obj = value as? JsonObject ?: return@mapNotNull null
            val id = obj["terminalId"]?.jsonPrimitive?.content ?: return@mapNotNull null
            key to (id to (obj["at"]?.jsonPrimitive?.content?.toLongOrNull() ?: 0L))
        }.toMap(LinkedHashMap())
    }

    fun get(key: String): String? = entries()[key]?.first

    fun set(key: String, terminalId: String?) {
        val entries = entries()
        if (terminalId == null) entries.remove(key) else entries[key] = terminalId to ++clock
        while (entries.size > MAX) entries.remove(entries.minBy { it.value.second }.key)
        val json = JsonObject(entries.mapValues { (_, value) -> JsonObject(mapOf("terminalId" to JsonPrimitive(value.first), "at" to JsonPrimitive(value.second))) })
        runCatching { storage()?.write(FILE, json.toString().encodeToByteArray()) }
    }

    /** Clears the cache when the gateway (and so the storage) changes. */
    fun reload() {
        cache = null
    }

    private companion object {
        const val FILE = "terminal-selection.json"
        const val MAX = 64
    }
}
