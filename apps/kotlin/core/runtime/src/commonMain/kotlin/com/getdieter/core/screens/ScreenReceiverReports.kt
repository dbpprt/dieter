package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopReceiverFeedback
import com.getdieter.api.v1.RemoteDesktopReference
import kotlin.time.Clock
import okio.ByteString

/**
 * What the receiver tells the host's encoder on the session channel: measurements, whether input is
 * active, and the reference frames it decoded, for loss recovery. Reports also renew the lease.
 * [ScreenSession] owns it and stops it with each attempt; confined to the core dispatcher.
 */
internal class ScreenReceiverReports(
    private val clock: Clock,
    private val engine: () -> ScreenMediaEngine?,
) {
    private var feedback: ScreenFeedback? = null
    private var references: ScreenReferences? = null

    private fun now() = clock.now()

    /** A new engine: references follow its decoder's timestamps. */
    fun prepare(millisecondTimestamps: Boolean) {
        references = ScreenReferences(millisecondTimestamps)
    }

    /** The binding was verified: reports carry its input [epoch] from now on. */
    fun start(epoch: ByteString) {
        feedback = ScreenFeedback(epoch).also { it.start(now()) }
    }

    fun measured(sample: RemoteDesktopReceiverFeedback) {
        feedback?.update(sample, now())
    }

    fun input(active: Boolean) {
        feedback?.input(active, now())
    }

    /** Sends a report, unless the session channel is closed or backed up. */
    fun send() {
        val current = engine() ?: return
        val pump = feedback ?: return
        if (
            !current.isOpen(ScreenChannels.SESSION) ||
                current.bufferedAmount(ScreenChannels.SESSION) >= ScreenFeedback.SKIP_BUFFERED_BYTES
        )
            return
        current.send(
            ScreenChannels.SESSION,
            RemoteDesktopReceiverFeedback.ADAPTER.encode(pump.next(now())),
        )
    }

    /** The host announced a reference frame; one already decoded is acknowledged at once. */
    fun expect(reference: RemoteDesktopReference) {
        acknowledge(references?.expect(reference, now()).orEmpty())
    }

    /** The decoder produced a frame; references waiting for it are acknowledged at once. */
    fun decoded(rtpTimestamp: UInt) {
        acknowledge(references?.decoded(rtpTimestamp, now()).orEmpty())
    }

    private fun acknowledge(acked: List<RemoteDesktopReference>) {
        if (acked.isEmpty()) return
        feedback?.acknowledge(acked)
        send()
    }

    /** The attempt stopped: nothing more is acknowledged or reported. */
    fun stop() {
        references?.stop()
        references = null
        feedback = null
    }
}
