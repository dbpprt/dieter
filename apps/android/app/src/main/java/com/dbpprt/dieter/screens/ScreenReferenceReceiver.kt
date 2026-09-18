package com.dbpprt.dieter.screens

import android.os.SystemClock
import com.dbpprt.dieter.v1.RemoteDesktopReference

internal const val SCREEN_GENERIC_DESCRIPTOR_URI = "http://www.webrtc.org/experiments/rtp-hdrext/generic-frame-descriptor-00"

/** The challenge and actual decoder output can arrive in either order. Histories
 * belong to one peer, expire after two seconds, and never retain video buffers. */
internal class ScreenReferenceReceiver(
    private val clock: () -> Long = SystemClock::elapsedRealtime,
    private val acknowledge: (List<RemoteDesktopReference>) -> Unit,
) {
    private val lock = Any()
    private var active = true
    private var generation = 0L
    private val decoded = ArrayDeque<Pair<Long, Long>>()
    private val pending = ArrayDeque<Pair<RemoteDesktopReference, Long>>()
    fun stop() = synchronized(lock) { active = false; decoded.clear(); pending.clear() }
    fun decoded(timestampNs: Long) = synchronized(lock) {
        if (!active) return@synchronized
        val now = clock()
        val rtp = (timestampNs / 1_000_000L * 90L) and 0xffff_ffffL
        decoded.removeAll { now - it.second >= 2_000 }
        if (decoded.none { it.first == rtp }) {
            if (decoded.size >= 128) decoded.removeFirst()
            decoded.addLast(rtp to now)
        }
        deliver(now)
    }
    fun expect(value: RemoteDesktopReference) = synchronized(lock) {
        if (!active || value.frameId <= 0 || value.generation <= 0 || value.generation < generation) return@synchronized
        if (value.generation > generation) { pending.clear(); generation = value.generation }
        if (pending.size >= 8) pending.removeFirst()
        pending.addLast(value to clock()); deliver(clock())
    }
    private fun deliver(now: Long) {
        val ready = mutableListOf<RemoteDesktopReference>()
        pending.removeAll { (value, at) ->
            val timestamp = (value.rtpTimestamp.toLong() and 0xffff_ffffL) / 90L * 90L
            when {
                now - at >= 2_000 -> true
                decoded.any { it.first == timestamp && now - it.second < 2_000 } -> { ready.add(value); true }
                else -> false
            }
        }
        if (ready.isNotEmpty()) acknowledge(ready)
    }
}
