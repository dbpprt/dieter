package com.dbpprt.dieter.core.terminals

import com.dbpprt.dieter.api.v1.TerminalInputRequest
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.withDeadline
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okio.Buffer

data class TerminalKey(val daemonId: String, val terminalId: String)

/**
 * Delivers typed and pasted input. Keystrokes queued while a write is in
 * flight ride the next write; writes are at most 64 KiB. Input is admitted
 * whole or not at all within a 1 MiB budget shared by at most 8 terminals,
 * and an unconfirmed write is never resent. Confined to the core dispatcher.
 */
class TerminalInputPumps(private val sessions: MachineSessions, private val scope: CoroutineScope) {
    private class Pump(val key: TerminalKey) {
        val pending = Buffer()
        var inFlight = 0L
        var job: Job? = null
    }

    private val pumps = LinkedHashMap<TerminalKey, Pump>()
    private val budgetUsed get() = pumps.values.sumOf { it.pending.size + it.inFlight }

    /** Queues [bytes]; throws when the budget or pump limit would be exceeded. [onFailure] reports a dropped write once. */
    fun send(key: TerminalKey, bytes: ByteArray, onFailure: (String) -> Unit) {
        if (bytes.isEmpty()) return
        val pump = pumps[key]
        if (pump == null && pumps.size >= MAX_PUMPS) throw CoreException(FailureKind.TRANSIENT, "Too many terminals are receiving input. Wait for them to catch up.")
        if (budgetUsed + bytes.size > MAX_BUDGET_BYTES) throw CoreException(FailureKind.TRANSIENT, "Terminal input is still being delivered. Paste less at once.")
        val target = pump ?: Pump(key).also { pumps[key] = it }
        target.pending.write(bytes)
        if (target.job?.isActive == true) return
        target.job = scope.launch {
            delay(START_DELAY)
            while (target.pending.size > 0) {
                val chunk = target.pending.readByteString(minOf(target.pending.size, CHUNK_BYTES.toLong()))
                target.inFlight = chunk.size.toLong()
                try {
                    withDeadline(DEADLINE) {
                        sessions.call(key.daemonId) { it.WriteTerminal().execute(TerminalInputRequest(terminal_id = key.terminalId, data_ = chunk)) }
                    }
                } catch (cancelled: CancellationException) {
                    target.pending.clear()
                    throw cancelled
                } catch (error: Throwable) {
                    // Delivery may have happened; resending could duplicate a command.
                    target.pending.clear()
                    onFailure("${Failures.message(error)} Unconfirmed input was not resent.")
                } finally {
                    target.inFlight = 0
                }
            }
            if (pumps[key] === target && target.pending.size == 0L) pumps.remove(key)
        }
    }

    /** Drops [key]'s queued input, e.g. when its route or surface goes away. */
    fun cancel(key: TerminalKey) {
        pumps.remove(key)?.let {
            it.job?.cancel()
            it.pending.clear()
        }
    }

    fun cancelAll() {
        pumps.values.forEach { it.job?.cancel(); it.pending.clear() }
        pumps.clear()
    }

    companion object {
        const val MAX_BUDGET_BYTES = 1024L * 1024
        const val MAX_PUMPS = 8
        const val CHUNK_BYTES = 64 * 1024
        private val START_DELAY = 12.milliseconds
        private val DEADLINE = 15.seconds
    }
}
