package com.dbpprt.dieter.screens

/** One retained real decoded frame while reliable generation metadata catches up.
 * Video can beat SCTP; dropping that sole frame would freeze an idle new display.
 * All ownership changes are serialized, including stale decoder callbacks.
 */
internal class ScreenFrameGate<F>(
    private val timestamp: (F) -> Long, private val retain: (F) -> Unit,
    private val release: (F) -> Unit, private val emit: (F, Long) -> Unit,
) {
    private var epoch = -1L
    private var display = 0L
    private var media = 0L
    private var boundary = 0
    private var pending: F? = null

    @Synchronized fun update(token: Long, display: Long, media: Long, boundary: Int) {
        // Reliable display metadata can follow the first decoded frame. Keep
        // that one frame across display changes; the RTP boundary decides
        // whether it belongs. Only a session change invalidates it outright.
        if (token != epoch) discard()
        epoch = token; this.display = display; this.media = media; this.boundary = boundary
        if (ready()) {
            pending?.let { frame ->
                pending = null
                try { if (belongsToGeneration(timestamp(frame), boundary)) emit(frame, epoch) }
                finally { release(frame) }
            }
        }
    }
    @Synchronized fun offer(frame: F, token: Long) {
        if (token != epoch) return
        if (ready()) {
            if (belongsToGeneration(timestamp(frame), boundary)) emit(frame, token)
        } else {
            retain(frame)
            discard()
            pending = frame
        }
    }
    @Synchronized fun clear() { discard(); epoch = -1; display = 0; media = 0 }
    private fun ready() = display > 0 && media == display
    private fun discard() { pending?.let(release); pending = null }
}
