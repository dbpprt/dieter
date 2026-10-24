package com.getdieter.core.client

import com.getdieter.client.v1.Failure
import com.getdieter.core.CoreRuntime
import com.getdieter.core.admin.MachineTelemetry
import com.getdieter.core.board.BoardViewSurface
import com.getdieter.core.channels.Channels
import com.getdieter.core.executions.Processes
import com.getdieter.core.navigation.ChatsSurface
import com.getdieter.core.schedules.Schedules
import com.getdieter.core.screens.ScreenSurface
import com.getdieter.core.terminals.TerminalOverview
import com.getdieter.core.terminals.Terminals
import com.getdieter.core.workspace.ProjectChanges
import com.getdieter.core.workspace.ProjectWorkspaces
import com.getdieter.core.workspace.WorkspaceReview

/**
 * View-owned instances of a core surface, by scope, while observed. The last release runs [stop],
 * which ends the work the view left running.
 */
internal class Surfaces<T>(
    private val stop: (T) -> Unit = {},
    private val create: (scope: String) -> T,
) {
    private val open = mutableMapOf<String, Pair<T, Int>>()

    fun retain(scope: String): T {
        val (surface, refs) = open[scope] ?: (create(scope) to 0)
        open[scope] = surface to refs + 1
        return surface
    }

    fun release(scope: String) {
        val (surface, refs) = open[scope] ?: return
        if (refs > 1) {
            open[scope] = surface to refs - 1
            return
        }
        open.remove(scope)
        stop(surface)
    }

    operator fun get(scope: String): T? = open[scope]?.first

    /**
     * The surface that commands without a scope reach: the unscoped view's, opened on first use and
     * kept for the API's lifetime.
     */
    fun unscoped(): T = get(UNSCOPED) ?: retain(UNSCOPED)

    /**
     * The surface a command with [scope] reaches: the observed one, or the unscoped one for an
     * empty scope.
     */
    fun scoped(scope: String, missing: String): T =
        if (scope == UNSCOPED) unscoped() else get(scope) ?: invalid(missing)

    val all: List<T>
        get() = open.values.map { it.first }

    companion object {
        const val UNSCOPED = ""
    }
}

/** Every surface the API's views own, by kind. Confined to the core dispatcher. */
internal class ViewSurfaces(runtime: CoreRuntime, screenHost: ScreenHost?) {
    val files = Surfaces { runtime.files() }
    val fileTrees = Surfaces { runtime.fileTree() }
    val terminals = Surfaces(Terminals::stop) { runtime.terminals() }
    val overviews = Surfaces(TerminalOverview::stop) { runtime.terminalOverview() }
    val screens =
        Surfaces(ScreenSurface::stop) { scope ->
            val host =
                screenHost
                    ?: throw ClientFailure(
                        Failure(
                            Failure.Kind.KIND_PERMANENT,
                            "Screen sharing is unavailable on this device.",
                        )
                    )
            // Each view's engines render into that view.
            ScreenSurface(
                runtime.screen(host.engines(scope), host.config, host.clipboard),
                runtime.scope,
            )
        }
    val processes = Surfaces(Processes::stop) { Processes(runtime.sessions, runtime.scope) }
    val reviews = Surfaces(WorkspaceReview::stop) { runtime.workspaceReview() }
    val projectChanges = Surfaces(ProjectChanges::stop) { runtime.projectChanges() }
    val projectWorkspaces = Surfaces {
        ProjectWorkspaces(runtime.sessions, runtime.workspace, runtime.choice)
    }
    val schedules =
        Surfaces(Schedules::stop) {
            Schedules(
                runtime.sessions,
                runtime.workspace,
                runtime.choice,
                runtime.scope,
                runtime.metadata,
            )
        }
    val telemetry =
        Surfaces(MachineTelemetry::stop) { MachineTelemetry(runtime.sessions, runtime.scope) }
    val boardViews = Surfaces {
        BoardViewSurface(
            runtime.workspace.state,
            runtime.board,
            runtime.outbox.view,
            runtime.navigationKv.values,
            runtime.connection.machines,
        )
    }
    val chats =
        Surfaces(ChatsSurface::stop) {
            ChatsSurface(runtime.workspace.state, runtime.navigationKv.values, runtime.scope) {
                runtime.archivedChats()
            }
        }
    val creationPreviews = Surfaces { CreationPreviewSurface(runtime) }
    val channels =
        Surfaces(Channels::stop) {
            Channels(
                runtime.sessions,
                runtime.choice::reachable,
                runtime.channelSettings.view,
                runtime.scope,
                runtime.platform.logger,
            )
        }

    /** Open conversations by card ID; the runtime keeps the sessions themselves. */
    val conversations = Surfaces<String>(runtime.conversations::close) { it }

    /** The account changed: what surfaces showed of the previous one goes. */
    fun resetAccount() {
        processes.all.forEach(Processes::stop)
        projectWorkspaces.all.forEach(ProjectWorkspaces::reset)
        schedules.all.forEach(Schedules::stop)
        telemetry.all.forEach(MachineTelemetry::reset)
        chats.all.forEach(ChatsSurface::reset)
        channels.all.forEach(Channels::stop)
    }
}
