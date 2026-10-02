package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.Outcome
import com.dbpprt.dieter.client.v1.ProcessesCommand
import com.dbpprt.dieter.client.v1.QuotasCommand
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.client.v1.SchedulesCommand
import com.dbpprt.dieter.client.v1.TelemetryCommand
import com.dbpprt.dieter.core.admin.MachineTelemetry
import com.dbpprt.dieter.core.executions.ProcessTarget
import com.dbpprt.dieter.core.executions.Processes
import com.dbpprt.dieter.core.quotas.ProviderQuotas
import com.dbpprt.dieter.core.schedules.Schedules

internal suspend fun Processes.execute(command: ProcessesCommand): Result {
    command.bind?.let {
        val target = if (it.daemon_id.isEmpty() || it.card_id.isEmpty()) null else ProcessTarget(it.daemon_id, it.project_id, it.card_id)
        bind(target, it.active)
    }
    command.select?.let { select(it.execution_id) }
    command.stop?.let { stopSelected() }
    return Result(processes = processesSlice(view.value))
}

/** The result is a machine operation's response, else done. */
internal suspend fun MachineTelemetry.execute(command: TelemetryCommand): Result {
    command.perform?.let { request -> return perform(request.action)?.let { Result(machine_operation = it) } ?: Result(done = Done()) }
    command.select?.let { select(it.daemon_id.ifEmpty { null }, it.active) }
    return Result(done = Done())
}

/** The result is whether a reset was accepted, else done. */
internal suspend fun ProviderQuotas.execute(command: QuotasCommand): Result {
    command.consume_reset?.let { return Result(outcome = Outcome(succeeded = consumeReset(it.account_key))) }
    command.load?.let { load(it.refresh) }
    command.set_included?.let { setIncluded(it.provider, it.account_key, it.included) }
    return Result(done = Done())
}

/**
 * The result is a schedule, a draft, or the schedules after [command];
 * [harnesses] names each schedule's agent by its owner machine's catalog.
 */
internal suspend fun Schedules.execute(command: SchedulesCommand, harnesses: (daemonId: String) -> List<Harness>): Result {
    command.draft?.let { request ->
        val draft = draft(request.schedule_id.ifEmpty { null }, request.checkout_id.ifEmpty { null }, request.selected_board_id.ifEmpty { null }, request.timezone)
        return Result(schedule_draft = draft)
    }
    command.save?.let { request ->
        val draft = request.draft ?: invalid("A schedule draft is required.")
        return Result(schedule = save(draft, request.schedule_id.ifEmpty { null }, request.checkout_id.ifEmpty { null }))
    }
    command.set_enabled?.let { return Result(schedule = setEnabled(it.schedule_id, it.enabled)) }
    command.bind?.let { bind(it.project_id.ifEmpty { null }) }
    command.load?.let { load() }
    command.load_more?.let { loadMore() }
    command.select?.let { select(it.schedule_id) }
    command.load_more_runs?.let { loadMoreRuns() }
    command.preview?.let { preview(it.cron, it.timezone) }
    command.close_editor?.let { closeEditor() }
    command.run_now?.let { runNow(it.schedule_id) }
    command.delete?.let { delete(it.schedule_id) }
    return Result(schedules = schedulesSlice(view.value, harnesses))
}
