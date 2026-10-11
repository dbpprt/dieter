package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.client.v1.SessionSlice

/** A refresh does not imply that any machine changed presence. */
object RefreshPresentation {
    fun label(session: SessionSlice?, requested: Boolean = false): String =
        if (
            requested ||
                session?.phase == SessionSlice.Phase.PHASE_CONNECTING ||
                session?.phase == SessionSlice.Phase.PHASE_RECONNECTING ||
                (session?.phase == SessionSlice.Phase.PHASE_CONNECTED && !session.synced)
        )
            "Refreshing devices"
        else ""
}
