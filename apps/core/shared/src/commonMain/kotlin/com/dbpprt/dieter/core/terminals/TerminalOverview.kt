package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.CreateTerminalRequest
import com.dbpprt.dieter.api.v1.ListTerminalsRequest
import com.dbpprt.dieter.api.v1.Terminal
import com.dbpprt.dieter.core.machines.Machine
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** One terminal in the account-wide overview. */
data class TerminalOverviewEntry(val daemonId: String, val machineName: String, val terminal: Terminal) {
    val id: String get() = "$daemonId|${terminal.id}"
}

data class TerminalOverviewView(
    val entries: List<TerminalOverviewEntry> = emptyList(),
    val selectedId: String? = null,
    val loading: Boolean = false,
    /** Machines that could not be listed, by machine name. */
    val errors: Map<String, String> = emptyMap(),
    /** No compatible machine is online. */
    val noMachines: Boolean = false,
)

object TerminalOverviewCatalog {
    /** Oldest first, then by machine name, then by ID. */
    fun sorted(entries: List<TerminalOverviewEntry>): List<TerminalOverviewEntry> = entries.sortedWith(
        compareBy<TerminalOverviewEntry> { it.terminal.created_at }.thenBy { it.machineName.lowercase() }.thenBy { it.id },
    )

    /** Keeps the current selection, else the preferred machine's first terminal, else the first. */
    fun selection(entries: List<TerminalOverviewEntry>, currentId: String?, preferredDaemonId: String?): TerminalOverviewEntry? =
        entries.firstOrNull { it.id == currentId } ?: entries.firstOrNull { it.daemonId == preferredDaemonId } ?: entries.firstOrNull()
}

/**
 * Every terminal on every online machine, listed machine by machine so one
 * slow machine never holds the rest back. Selecting an entry points the
 * [terminals] surface at that machine. Confined to the core dispatcher.
 */
class TerminalOverview(
    private val sessions: MachineSessions,
    private val machines: () -> List<Machine>,
    val terminals: Terminals,
) {
    private val mutableView = MutableStateFlow(TerminalOverviewView())
    val view: StateFlow<TerminalOverviewView> = mutableView.asStateFlow()
    private var generation = 0L
    private var preferred: String? = null
    /** Machines the last load listed; null before the first load. */
    private var listed: Set<String>? = null
    private var staleChecks = 0

    suspend fun load(preferredDaemonId: String? = null) {
        val bound = ++generation
        preferred = preferredDaemonId
        val candidates = machines()
        if (candidates.isEmpty()) {
            listed = emptySet()
            mutableView.value = TerminalOverviewView(noMachines = true)
            terminals.bind(null)
            return
        }
        mutableView.update { it.copy(loading = it.entries.isEmpty(), noMachines = false) }
        val listed = mutableListOf<TerminalOverviewEntry>()
        val reached = mutableSetOf<String>()
        val errors = LinkedHashMap<String, String>()
        for (machine in candidates) {
            try {
                val values = withDeadline(DEADLINE) { sessions.call(machine.id) { it.ListTerminals().execute(ListTerminalsRequest()) } }.terminals
                listed += values.map { TerminalOverviewEntry(machine.id, machine.name, it) }
                reached += machine.id
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                errors[machine.name] = Failures.message(error)
            }
            if (bound != generation) return
            mutableView.update { it.copy(entries = TerminalOverviewCatalog.sorted(listed)) }
        }
        this.listed = reached
        val entries = TerminalOverviewCatalog.sorted(listed)
        val selected = TerminalOverviewCatalog.selection(entries, view.value.selectedId, preferredDaemonId)
        mutableView.update { it.copy(entries = entries, errors = errors, loading = false) }
        activate(selected)
    }

    suspend fun select(entryId: String) {
        val entry = view.value.entries.firstOrNull { it.id == entryId } ?: return
        generation++
        activate(entry)
    }

    /** Creates a terminal on [daemonId] and selects it; [machineHome] ignores the project checkout. */
    suspend fun create(
        daemonId: String, projectId: String = "", checkoutId: String = "", machineHome: Boolean = true,
        name: String = "", shell: String = "", workingDirectory: String = "",
    ): TerminalOverviewEntry {
        val machine = machines().firstOrNull { it.id == daemonId } ?: throw CoreException(FailureKind.TRANSIENT, "The selected machine is unavailable.")
        val request = CreateTerminalRequest(
            project_id = projectId, checkout_id = if (machineHome) "" else checkoutId, name = name.trim(), shell = shell,
            working_directory = workingDirectory.trim(), columns = 120, rows = 36, machine_home = machineHome,
        )
        val terminal = withDeadline(DEADLINE) { sessions.call(daemonId) { it.CreateTerminal().execute(request) } }
        val entry = TerminalOverviewEntry(daemonId, machine.name, terminal)
        generation++
        mutableView.update { state -> state.copy(entries = TerminalOverviewCatalog.sorted(state.entries.filterNot { it.id == entry.id } + entry)) }
        activate(entry)
        return entry
    }

    /**
     * Shows a close or rename made through the [terminals] surface without
     * another listing: [terminalId]'s entry takes the surface's terminal, or
     * leaves when the surface no longer has it. A closed selection follows the
     * surface's.
     */
    fun follow(terminalId: String) {
        val surface = terminals.view.value
        val scope = surface.scope ?: return
        if (scope.kind != TerminalScopeKind.MACHINE) return
        val id = "${scope.daemonId}|$terminalId"
        val current = view.value
        if (current.entries.none { it.id == id }) return
        val terminal = surface.terminals.firstOrNull { it.id == terminalId }
        val entries = if (terminal == null) current.entries.filterNot { it.id == id } else current.entries.map { if (it.id == id) it.copy(terminal = terminal) else it }
        val selected = if (current.selectedId != id || terminal != null) current.selectedId
            else surface.selectedId?.let { "${scope.daemonId}|$it" }?.takeIf { next -> entries.any { it.id == next } }
        mutableView.update { it.copy(entries = TerminalOverviewCatalog.sorted(entries), selectedId = selected) }
    }

    /**
     * Lists again when the online machines differ from those the last load
     * listed: a machine came online or back after a restart, went away, or
     * could not be listed. Repeated misses back off. Nothing before the first
     * load.
     */
    suspend fun relistIfStale() {
        val covered = listed ?: return
        val online = machines().map { it.id }.toSet()
        if (online == covered) {
            staleChecks = 0
            return
        }
        staleChecks++
        // Every check at first, then every 2nd, 4th, …, at most every 8th.
        val spacing = 1 shl minOf(3, (staleChecks - 1) / 3)
        if ((staleChecks - 1) % spacing == 0) load(preferred)
    }

    private suspend fun activate(entry: TerminalOverviewEntry?) {
        mutableView.update { it.copy(selectedId = entry?.id) }
        if (entry == null) return terminals.bind(null)
        terminals.bind(TerminalScope(entry.daemonId, TerminalScopeKind.MACHINE))
        terminals.load()
        terminals.select(entry.terminal.id)
    }

    private companion object {
        val DEADLINE = 15.seconds
    }
}
