package com.dbpprt.dieter.ui

import java.util.ArrayDeque
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive

/** Main-dispatcher owner. The budget includes bytes held by suspended RPCs. */
internal class TerminalInputController(
    private val scope: CoroutineScope,
    private val onFailure: (Throwable) -> Unit,
    private val byteLimit: Int = 256 * 1024,
    private val sessionLimit: Int = 8,
    private val pause: suspend () -> Unit = { delay(12) },
) {
    private class Pump(val write: suspend (ByteArray) -> Unit) {
        val chunks = ArrayDeque<ByteArray>()
        var bytes = 0
        var inFlight = 0
        var job: Job? = null
    }
    private val pumps = mutableMapOf<String, Pump>()
    private val owners = mutableSetOf<Pump>()
    private var admittedBytes = 0

    init { require(byteLimit > 0 && sessionLimit > 0) }

    /** Admission is all-or-nothing, copies caller data once, and never retries an ambiguous write. */
    fun send(id: String, data: ByteArray, write: suspend (ByteArray) -> Unit): Boolean {
        if (!scope.isActive) return false
        if (data.isEmpty()) return true
        if (data.size > byteLimit - admittedBytes || (id !in pumps && owners.size >= sessionLimit)) return false
        val pump = pumps[id] ?: Pump(write).also { pumps[id] = it; owners.add(it) }
        terminalInputChunks(data).forEach(pump.chunks::addLast)
        pump.bytes += data.size
        admittedBytes += data.size
        if (pump.job != null) return true
        pump.job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (pumps[id] === pump && pump.chunks.isNotEmpty()) {
                    pause()
                    if (pumps[id] !== pump) break
                    val chunk = pump.chunks.removeFirst()
                    pump.inFlight = chunk.size
                    pump.write(chunk)
                    if (pumps[id] !== pump) break
                    pump.bytes -= chunk.size
                    admittedBytes -= chunk.size
                    pump.inFlight = 0
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (pumps[id] === pump) onFailure(error)
            }
        }
        pump.job!!.invokeOnCompletion { finish(id, pump) }
        pump.job!!.start()
        return true
    }

    private fun finish(id: String, pump: Pump) {
        if (pumps[id] === pump) pumps.remove(id)
        owners.remove(pump)
        admittedBytes -= pump.bytes
        pump.bytes = 0
        pump.chunks.clear()
    }

    fun cancel(id: String) {
        val pump = pumps[id] ?: return
        pumps.remove(id)
        admittedBytes -= pump.bytes - pump.inFlight
        pump.bytes = pump.inFlight
        pump.chunks.clear()
        pump.job?.cancel()
    }

    fun cancelAll() = pumps.keys.toList().forEach(::cancel)
}
