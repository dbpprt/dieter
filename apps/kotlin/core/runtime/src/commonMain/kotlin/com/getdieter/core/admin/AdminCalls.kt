package com.getdieter.core.admin

import com.getdieter.core.api.DaemonApi
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import kotlin.time.Duration
import kotlin.uuid.Uuid
import okio.ByteString

/** Which machine must receive an administrative call. */
sealed interface AdminRoute {
    /**
     * A reachable machine that holds the project: the peer store accepts and replicates the write.
     */
    data class ForProject(val projectId: String) : AdminRoute

    /** The machine holding a checkout's path, validation commands, and leases. */
    data class Owner(val checkoutId: String, val projectId: String) : AdminRoute

    /** A machine the user chose, e.g. to host a new project. */
    data class Target(val daemonId: String) : AdminRoute

    /**
     * A reachable machine that observed every version of the register [key], for a
     * compare-and-swap; else [ForProject].
     */
    data class Observer(val key: String, val projectId: String) : AdminRoute

    /** Any reachable machine, this device's first. */
    data object Anywhere : AdminRoute

    companion object {
        /**
         * Shared records of [projectId] live on every machine that holds it; without a project, on
         * any.
         */
        fun shared(projectId: String?): AdminRoute =
            projectId?.takeIf { it.isNotEmpty() }?.let(::ForProject) ?: Anywhere
    }
}

/**
 * Routes the administrative calls of every [Administration] part to the machine [MachineChoice]
 * picks, and keeps one operation ID per pending intent so a retry is idempotent. Confined to the
 * core dispatcher.
 */
internal class AdminCalls(
    private val sessions: MachineSessions,
    private val store: WorkspaceStore,
    private val choice: MachineChoice,
) {
    /** Intent → its operation ID, oldest first; an intent is forgotten once it succeeded. */
    private val operationIds = LinkedHashMap<String, String>()

    /** Intents whose operation ID is kept for a retry. */
    val pendingIntents: Int
        get() = operationIds.size

    fun daemonFor(route: AdminRoute): String {
        val directory = store.directoryProjection
        return when (route) {
            is AdminRoute.Target -> route.daemonId
            is AdminRoute.ForProject ->
                choice.project(route.projectId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "No machine with this project is reachable.",
                    )
            is AdminRoute.Observer ->
                choice.observer(route.key)
                    ?: choice.project(route.projectId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "No machine with this project is reachable.",
                    )
            is AdminRoute.Owner ->
                directory.checkoutMachine(route.projectId, route.checkoutId)
                    ?: throw CoreException(
                        FailureKind.TRANSIENT,
                        "The checkout’s machine is unavailable",
                    )
            AdminRoute.Anywhere ->
                choice.any()
                    ?: throw CoreException(FailureKind.TRANSIENT, "No machine is reachable.")
        }
    }

    suspend fun <T> call(
        route: AdminRoute,
        timeout: Duration = Deadlines.CALL,
        block: suspend (DaemonApi) -> T,
    ): T = sessions.call(daemonFor(route), timeout, block)

    /** The project whose machines hold [boardId], for routing the board's calls. */
    fun projectOf(boardId: String): String =
        store.findBoard(boardId)?.project_id
            ?: throw CoreException(FailureKind.PERMANENT, "The board is no longer available.")

    /**
     * Runs [block] with one operation ID per distinct intent, so a retry of the same intent is
     * idempotent and an edit is not. The ID is kept until the intent succeeds; only the newest
     * [MAX_INTENTS] are kept.
     */
    suspend fun <T> idempotent(
        kind: String,
        fingerprint: ByteString,
        block: suspend (operationId: String) -> T,
    ): T {
        val key = kind + ":" + fingerprint.sha256().hex()
        val id = operationIds.remove(key) ?: Uuid.random().toString()
        operationIds[key] = id
        while (operationIds.size > MAX_INTENTS) operationIds.remove(operationIds.keys.first())
        return block(id).also { operationIds.remove(key) }
    }

    companion object {
        const val MAX_INTENTS = 64
    }
}
