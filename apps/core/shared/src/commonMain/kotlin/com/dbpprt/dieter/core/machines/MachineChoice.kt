package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.connection.MachineDirectory
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.session.MachineRoute
import com.dbpprt.dieter.core.store.WorkspaceStore
import com.dbpprt.dieter.core.sync.AccountSync
import kotlinx.coroutines.flow.StateFlow

/**
 * Which machine serves what, one rule set for every surface. A card's own
 * work goes to its owner; project-wide reads and shared writes go to a
 * reachable machine that holds the data, this device's first; a
 * compare-and-swap goes where the joined register was observed. No machine
 * is chosen once for everything.
 */
class MachineChoice(
    private val store: WorkspaceStore,
    private val sync: AccountSync,
    private val machines: StateFlow<MachineDirectory>,
    private val routes: StateFlow<Map<String, MachineRoute>>,
) {
    /** Online, compatible machines: this device's first, then by name. */
    fun reachable(): List<String> = ordered(machines.value, routes.value)

    /** This device's machine, when it runs a reachable one. */
    fun local(): String? = reachable().firstOrNull { routes.value[it]?.kind == RouteKind.LOCAL }

    /** The machine that runs [card]'s conversation, reachable or not. */
    fun owner(card: Card): String? = store.directoryProjection.owner(card)

    /** A reachable machine for an account-wide call. */
    fun any(): String? = reachable().firstOrNull()

    /**
     * A reachable machine for [projectId]'s project-wide reads and shared
     * records: one with a checkout of it, else any that holds the project.
     */
    fun project(projectId: String): String? {
        val directory = store.directoryProjection
        val checkouts = directory.projects[projectId]?.checkouts.orEmpty().filterNot { it.detached }.mapTo(HashSet()) { directory.machine(it.daemon_id) }
        val reachable = reachable()
        return reachable.firstOrNull { it in checkouts } ?: reachable.firstOrNull { sync.replica(it)?.record("project/$projectId.identity") != null }
    }

    /**
     * A machine with a checkout of [projectId] for work that runs there: a
     * reachable one first, else one that is offline now, so the work can
     * wait for it.
     */
    fun checkout(projectId: String): String? {
        val directory = store.directoryProjection
        val holders = directory.projects[projectId]?.checkouts.orEmpty().filterNot { it.detached }.map { directory.machine(it.daemon_id) }.distinct().sorted()
        return reachable().firstOrNull { it in holders } ?: holders.firstOrNull()
    }

    /** A reachable machine that holds the register [key], [preferred] first, e.g. for a card's shared fields. */
    fun holder(key: String, preferred: String? = null): String? {
        val reachable = reachable()
        val holders = reachable.filter { sync.replica(it)?.record(key) != null }
        return holders.firstOrNull { it == preferred } ?: holders.firstOrNull()
    }

    /**
     * A reachable machine whose copy of the register [key] has every version
     * the account view joined, [preferred] first: a compare-and-swap there
     * checks against what this client shows. Null while none has.
     */
    fun observer(key: String, preferred: String? = null): String? {
        val observers = sync.observers(key).toSet()
        val candidates = reachable().filter { it in observers }
        return candidates.firstOrNull { it == preferred } ?: candidates.firstOrNull()
    }

    companion object {
        /** Online, compatible machines of [directory]: those reached over a loopback route first, then by name. */
        fun ordered(directory: MachineDirectory, routes: Map<String, MachineRoute>): List<String> =
            directory.all.filter { it.online(directory.evaluatedAt) && it.compatible }
                .sortedWith(compareBy<Machine>({ routes[it.id]?.kind != RouteKind.LOCAL }, { it.name.lowercase() }, { it.id }))
                .map { it.id }
    }
}
