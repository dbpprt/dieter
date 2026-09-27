package com.dbpprt.dieter.ui

import com.dbpprt.dieter.data.TerminalClient
import com.dbpprt.dieter.v1.CreateTerminalRequest
import com.dbpprt.dieter.v1.Terminal
import com.dbpprt.dieter.v1.TerminalFrame
import io.grpc.Status
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive

data class TerminalWorkspaceState(
    val terminals: List<Terminal> = emptyList(),
    val selectedTerminalId: String? = null,
    val terminalScreens: Map<String, TerminalScreenState> = emptyMap(),
    val terminalLoading: Boolean = false,
    val terminalStreamConnected: Boolean = false,
    val terminalCreateVisible: Boolean = false,
)

/** Owns terminal state and local tasks; disposing a surface never closes a daemon terminal. */
internal class TerminalController(
    private val scope: CoroutineScope,
    private val captureClient: () -> TerminalClient,
    private val canWatch: () -> Boolean,
    private val publish: (TerminalWorkspaceState) -> Unit,
    private val reportError: (String) -> Unit,
) {
    var state = TerminalWorkspaceState()
        private set
    private var binding: Any? = null
    private var generation = 0L
    private var listGeneration = 0L
    private var watchGeneration = 0L
    private var listJob: Job? = null
    private var watchJob: Job? = null
    private val mutations = mutableSetOf<Job>()
    private val resizeJobs = mutableMapOf<String, Job>()
    private val sequences = mutableMapOf<String, Long>()
    private val input = TerminalInputController(scope, { error ->
        update { it.copy(terminalStreamConnected = false) }
        reportError("Terminal input paused: ${message(error)}")
    })

    private fun update(change: (TerminalWorkspaceState) -> TerminalWorkspaceState) {
        state = change(state)
        publish(state)
    }

    fun bind(value: Any?) {
        if (binding == value) return
        binding = value
        cancel()
        sequences.clear()
        update { TerminalWorkspaceState() }
    }

    fun cancel() {
        generation++
        listGeneration++
        listJob?.cancel()
        listJob = null
        stopWatch()
        input.cancelAll()
        resizeJobs.values.forEach { it.cancel() }
        resizeJobs.clear()
        mutations.toList().forEach { it.cancel() }
        mutations.clear()
        update { it.copy(terminalLoading = false) }
    }

    fun load() {
        val owner = generation
        val request = ++listGeneration
        listJob?.cancel()
        update { it.copy(terminalLoading = true) }
        listJob = scope.launch {
            try {
                val client = captureClient()
                val terminals = client.terminals().terminalsList.sortedWith(order)
                if (!isActive || owner != generation || request != listGeneration) return@launch
                val live = terminals.mapTo(hashSetOf()) { it.id }
                update { it.copy(
                    terminals = terminals,
                    selectedTerminalId = it.selectedTerminalId?.takeIf(live::contains) ?: terminals.firstOrNull()?.id,
                    terminalScreens = it.terminalScreens.filterKeys(live::contains),
                    terminalLoading = false,
                ) }
                sequences.keys.retainAll(live)
                startWatch()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (error: Throwable) {
                if (owner == generation && request == listGeneration) {
                    update { it.copy(terminalLoading = false) }
                    reportError(message(error))
                }
            }
        }
    }

    fun showCreate(visible: Boolean) = update { it.copy(terminalCreateVisible = visible) }
    fun select(id: String) {
        if (state.terminals.none { it.id == id }) return
        update { it.copy(selectedTerminalId = id) }
        startWatch()
    }

    fun create(request: CreateTerminalRequest, onCreated: () -> Unit) = mutate { client, current ->
        update { it.copy(terminalLoading = true) }
        val terminal = client.create(request)
        if (current()) {
            sequences[terminal.id] = 0
            update { it.copy(terminals = upsert(it.terminals, terminal), selectedTerminalId = terminal.id,
                terminalScreens = it.terminalScreens + (terminal.id to TerminalScreenState()),
                terminalLoading = false, terminalCreateVisible = false) }
            onCreated()
            startWatch()
        }
    }

    fun send(id: String, data: ByteArray) {
        if (data.isEmpty() || state.terminals.none { it.id == id && it.status == "running" }) return
        try {
            val client = captureClient()
            if (!input.send(id, data) { client.write(id, it) }) {
                reportError("Terminal input is full. Wait for pending input before typing or pasting again.")
            }
        } catch (error: Throwable) { reportError(message(error)) }
    }

    fun resize(id: String, columns: Int, rows: Int) {
        if (columns !in 2..500 || rows !in 2..500) return
        resizeJobs.remove(id)?.cancel()
        resizeJobs[id] = mutate { client, current ->
            delay(120)
            val terminal = client.resize(id, columns, rows)
            if (current()) update { it.copy(terminals = upsert(it.terminals, terminal)) }
        }
    }

    fun rename(id: String, name: String) {
        if (name.isBlank()) return
        mutate { client, current ->
            val terminal = client.rename(id, name.trim())
            if (current()) update { it.copy(terminals = upsert(it.terminals, terminal)) }
        }
    }

    fun close(id: String) = mutate { client, current ->
        client.close(id)
        if (current()) {
            input.cancel(id)
            resizeJobs.remove(id)?.cancel()
            remove(id)
            startWatch()
        }
    }

    private fun mutate(block: suspend (TerminalClient, () -> Boolean) -> Unit): Job {
        val owner = generation
        val job = scope.launch {
            try { block(captureClient()) { isActive && owner == generation }
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (error: Throwable) {
                if (isActive && owner == generation) {
                    update { it.copy(terminalLoading = false) }
                    reportError(message(error))
                }
            }
        }
        mutations.add(job)
        job.invokeOnCompletion { mutations.remove(job) }
        return job
    }

    fun stopWatch() {
        watchGeneration++
        watchJob?.cancel()
        watchJob = null
        update { it.copy(terminalStreamConnected = false) }
    }

    private fun startWatch() {
        stopWatch()
        val id = state.selectedTerminalId ?: return
        if (!canWatch()) return
        val owner = generation
        val watch = watchGeneration
        watchJob = scope.launch {
            var backoff = 500L
            while (owner == generation && watch == watchGeneration && canWatch() && state.selectedTerminalId == id) {
                try {
                    // Each retry can renew credentials, but bind() invalidates this owner on route changes.
                    val client = captureClient()
                    client.watch(id, sequences[id] ?: 0).collectLatest { frame ->
                        if (owner == generation && watch == watchGeneration) accept(id, frame)
                    }
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (error: Throwable) {
                    if (owner != generation || watch != watchGeneration) return@launch
                    if (Status.fromThrowable(error).code == Status.Code.NOT_FOUND) { remove(id); return@launch }
                }
                if (owner != generation || watch != watchGeneration) return@launch
                update { it.copy(terminalStreamConnected = false) }
                delay(backoff)
                backoff = (backoff * 1.8).toLong().coerceAtMost(5_000)
            }
        }
    }

    private fun remove(id: String) {
        sequences.remove(id)
        update {
            val terminals = it.terminals.filterNot { terminal -> terminal.id == id }
            it.copy(terminals = terminals, selectedTerminalId = if (it.selectedTerminalId == id) terminals.firstOrNull()?.id else it.selectedTerminalId,
                terminalScreens = it.terminalScreens - id, terminalStreamConnected = false)
        }
    }

    private fun accept(id: String, frame: TerminalFrame) {
        sequences[id] = maxOf(sequences[id] ?: 0, frame.sequence)
        update { it.copy(
            terminals = if (frame.hasTerminal() && frame.terminal.id == id) upsert(it.terminals, frame.terminal) else it.terminals,
            terminalStreamConnected = true,
            terminalScreens = if (!frame.screenReset && frame.data.isEmpty) it.terminalScreens else it.terminalScreens +
                (id to TerminalScreenReducer.apply(it.terminalScreens[id] ?: TerminalScreenState(), frame.data.toByteArray(), frame.screenReset)),
        ) }
    }

    private fun upsert(items: List<Terminal>, terminal: Terminal) = (items.filterNot { it.id == terminal.id } + terminal).sortedWith(order)
    private fun message(error: Throwable): String = Status.fromThrowable(error).description?.takeIf { it.isNotBlank() }
        ?: error.message?.substringBefore('\n') ?: "Dieter could not complete the terminal request"
    private val order = compareBy<Terminal> { it.createdAt }.thenBy { it.id }
}
