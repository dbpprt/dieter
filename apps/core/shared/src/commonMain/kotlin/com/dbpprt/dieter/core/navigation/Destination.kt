package com.dbpprt.dieter.core.navigation

/** A top-level destination and what it needs from the connection. */
enum class Destination(
    /** Shows the synchronized workspace (projects, boards, conversations). */
    val synchronized: Boolean,
    /** Changes made offline queue in the outbox, so cached data stays usable. */
    val offlineOutbox: Boolean,
    /** Works on one project at a time, read live from its machine. */
    val projectScoped: Boolean,
) {
    ACTIVITY(true, true, false),
    CHATS(true, true, false),
    BOARD(true, true, false),
    MACHINES(false, false, false),
    TERMINALS(false, false, false),
    SCREENS(false, false, false),
    FILES(true, false, true),
    SCHEDULES(true, false, true),
}
