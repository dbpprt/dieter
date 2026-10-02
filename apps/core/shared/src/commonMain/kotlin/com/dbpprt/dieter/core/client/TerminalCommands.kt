package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.TerminalOverviewCommand
import com.dbpprt.dieter.client.v1.TerminalsCommand
import com.dbpprt.dieter.core.terminals.TerminalOverview
import com.dbpprt.dieter.core.terminals.Terminals

/**
 * The result is the created terminal or the surface after [command].
 * [overview] owns these terminals when they are an overview's.
 */
internal suspend fun Terminals.execute(command: TerminalsCommand, overview: TerminalOverview?): Result {
    command.create?.let { request ->
        val created = create(
            request.name.trim(), request.shell, request.working_directory.ifEmpty { null },
            request.columns.takeIf { it > 0 } ?: 120, request.rows.takeIf { it > 0 } ?: 36,
        )
        return Result(terminal = created)
    }
    command.bind?.let { bind(terminalScope(it)) }
    command.active?.let { setActive(it.on) }
    command.load?.let { load() }
    command.select?.let { select(it.terminal_id.ifEmpty { null }) }
    command.rename?.let { rename(it.terminal_id, it.name) }
    command.close?.let { close(it.terminal_id) }
    command.input?.let { input(it.data_.toByteArray()) }
    command.grid?.let { gridChanged(it.columns, it.rows) }
    // A close or rename through the overview's terminals updates its list.
    (command.close?.terminal_id ?: command.rename?.terminal_id)?.let { overview?.follow(it) }
    return Result(terminals = terminalsSlice(view.value, null))
}

internal suspend fun TerminalOverview.execute(command: TerminalOverviewCommand): Result {
    command.load?.let { load(it.preferred_daemon_id.ifEmpty { null }) }
    command.select?.let { select(it.terminal_id) }
    command.create?.let { create(it.daemon_id, it.project_id, it.checkout_id, it.machine_home, it.name, it.shell, it.working_directory) }
    return Result(terminal_overview = overviewSlice(view.value, terminalsSlice(terminals.view.value, null)))
}
