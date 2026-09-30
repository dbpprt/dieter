package com.dbpprt.dieter.core.executions

import com.dbpprt.dieter.api.v1.Execution
import com.dbpprt.dieter.api.v1.ExecutionEvent
import com.dbpprt.dieter.api.v1.ExecutionRef
import com.dbpprt.dieter.api.v1.ExecutionStream
import com.dbpprt.dieter.api.v1.ListExecutionsRequest
import com.dbpprt.dieter.api.v1.WatchExecutionRequest
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
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
import okio.Buffer
import okio.ByteString
import okio.ByteString.Companion.toByteString

/** The conversation whose background processes are shown. */
data class ProcessTarget(val daemonId: String, val projectId: String, val cardId: String)

data class ProcessesView(
    val target: ProcessTarget? = null,
    val processes: List<Execution> = emptyList(),
    val selectedId: String? = null,
    val stdout: ByteString = ByteString.EMPTY,
    val stderr: ByteString = ByteString.EMPTY,
    /** Older output was dropped, here or by the daemon. */
    val outputTruncated: Boolean = false,
    val loading: Boolean = false,
    val stopping: Boolean = false,
    val error: String? = null,
) {
    val running: Int get() = processes.count { it.status == "running" }
    val selected: Execution? get() = processes.firstOrNull { it.id == selectedId }
    val canStop: Boolean get() = !stopping && selected?.status == "running"
}

/**
 * Background processes an agent started for one conversation. While shown,
 * the list refreshes every 2 s and the selected process streams its output.
 * Hiding the panel never stops a process. Confined to the core dispatcher.
 */
class Processes(private val sessions: MachineSessions, private val scope: CoroutineScope) {
    private val mutableView = MutableStateFlow(ProcessesView())
    val view: StateFlow<ProcessesView> = mutableView.asStateFlow()
    private var generation = 0L
    private var poll: Job? = null
    private var watch: Job? = null
    private var watchedId: String? = null
    private var completedId: String? = null
    private var sequence = 0L

    /** Shows [target]'s processes while [active]; null or inactive stops refreshing. */
    fun bind(target: ProcessTarget?, active: Boolean) {
        val changed = target != view.value.target
        generation++
        poll?.cancel()
        stopWatch()
        completedId = null
        if (changed) {
            sequence = 0
            mutableView.value = ProcessesView(target = target)
        } else {
            mutableView.update { it.copy(loading = false, stopping = false, error = null) }
        }
        if (target == null || !active) return
        val bound = generation
        poll = scope.launch {
            while (bound == generation) {
                refresh(bound)
                delay(POLL)
            }
        }
    }

    private suspend fun refresh(bound: Long) {
        val target = view.value.target ?: return
        mutableView.update { it.copy(loading = true) }
        try {
            val listed = withDeadline(DEADLINE) {
                sessions.call(target.daemonId) { it.ListExecutions().execute(ListExecutionsRequest(project_id = target.projectId, card_id = target.cardId)) }
            }.executions.filter { it.card_id == target.cardId && it.project_id == target.projectId }
            if (bound != generation) return
            mutableView.update { state ->
                val merged = listed.map { incoming -> state.processes.firstOrNull { it.id == incoming.id && it.sequence.toULong() > incoming.sequence.toULong() } ?: incoming }
                    .sortedByDescending { it.created_at }
                state.copy(processes = merged, loading = false, error = null)
            }
            val state = view.value
            if (state.selected == null) state.processes.firstOrNull()?.let { select(it.id) } else startWatch()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == generation) mutableView.update { it.copy(loading = false, error = Failures.message(error)) }
        }
    }

    fun select(id: String) {
        val state = view.value
        if (state.processes.none { it.id == id }) return
        if (state.selectedId != id) {
            stopWatch()
            sequence = 0
            completedId = null
            mutableView.update { it.copy(selectedId = id, stdout = ByteString.EMPTY, stderr = ByteString.EMPTY, outputTruncated = false) }
        }
        startWatch()
    }

    private fun startWatch() {
        val state = view.value
        val target = state.target ?: return
        val id = state.selectedId ?: return
        if (watchedId == id || completedId == id || poll?.isActive != true) return
        watchedId = id
        val bound = generation
        watch = scope.launch {
            try {
                coroutineScope {
                    sessions.call(target.daemonId) { client ->
                        val call = client.WatchExecution()
                        val events = call.executeIn(this, WatchExecutionRequest(execution_id = id, after_sequence = sequence, heartbeat_ms = HEARTBEAT_MS))
                        try {
                            for (event in events) {
                                if (bound != generation || view.value.selectedId != id) break
                                receive(event, target)
                                if (event.eof) completedId = id
                            }
                        } finally {
                            call.cancel()
                        }
                    }
                }
            } catch (error: Throwable) {
                if (error is CancellationException) throw error
                if (bound == generation) mutableView.update { it.copy(error = Failures.message(error)) }
            } finally {
                // The next refresh resumes a watch that ended without end-of-output.
                if (watchedId == id) watchedId = null
            }
        }
    }

    private fun stopWatch() {
        watch?.cancel()
        watch = null
        watchedId = null
    }

    internal fun receive(event: ExecutionEvent, target: ProcessTarget) {
        val execution = event.execution
        if (execution != null) {
            if (execution.card_id != target.cardId || execution.project_id != target.projectId) return
            mutableView.update { state ->
                state.copy(processes = state.processes.map { if (it.id == execution.id && execution.sequence.toULong() >= it.sequence.toULong()) execution else it })
            }
        }
        if (event.heartbeat) return
        if (event.reset) {
            mutableView.update { it.copy(stdout = ByteString.EMPTY, stderr = ByteString.EMPTY, outputTruncated = execution?.output_truncated == true) }
        } else if (event.sequence.toULong() <= sequence.toULong()) {
            return
        }
        sequence = event.sequence
        if (execution?.output_truncated == true) mutableView.update { it.copy(outputTruncated = true) }
        when (event.stream) {
            ExecutionStream.EXECUTION_STREAM_STDOUT, ExecutionStream.EXECUTION_STREAM_PTY -> mutableView.update { state ->
                val (bytes, trimmed) = append(state.stdout, event.data_)
                state.copy(stdout = bytes, outputTruncated = state.outputTruncated || trimmed)
            }
            ExecutionStream.EXECUTION_STREAM_STDERR -> mutableView.update { state ->
                val (bytes, trimmed) = append(state.stderr, event.data_)
                state.copy(stderr = bytes, outputTruncated = state.outputTruncated || trimmed)
            }
            else -> Unit
        }
    }

    /** Stops the selected process; only an explicit stop ever ends one. */
    suspend fun stopSelected() {
        val state = view.value
        val target = state.target ?: return
        val selected = state.selected ?: return
        if (!state.canStop) return
        val bound = generation
        mutableView.update { it.copy(stopping = true) }
        try {
            val result = withDeadline(DEADLINE) { sessions.call(target.daemonId) { it.CancelExecution().execute(ExecutionRef(execution_id = selected.id)) } }
            if (bound == generation) mutableView.update { current -> current.copy(processes = current.processes.map { if (it.id == result.id) result else it }) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == generation) mutableView.update { it.copy(error = Failures.message(error)) }
        } finally {
            if (bound == generation) mutableView.update { it.copy(stopping = false) }
        }
    }

    companion object {
        const val MAX_STREAM_BYTES = 128 * 1024
        const val HEARTBEAT_MS = 15_000
        private val POLL = 2.seconds
        private val DEADLINE = 15.seconds

        /** Appends and keeps the newest bytes, cutting at a UTF-8 character boundary. */
        fun append(current: ByteString, data: ByteString): Pair<ByteString, Boolean> {
            if (current.size + data.size <= MAX_STREAM_BYTES) return (Buffer().write(current).write(data).readByteString()) to false
            val joined = Buffer().write(current).write(data).readByteString()
            var start = joined.size - MAX_STREAM_BYTES
            // Skip continuation bytes (10xxxxxx) so the kept text starts on a character.
            while (start < joined.size && (joined[start].toInt() and 0xC0) == 0x80) start++
            return joined.substring(start).toByteArray().toByteString() to true
        }
    }
}
