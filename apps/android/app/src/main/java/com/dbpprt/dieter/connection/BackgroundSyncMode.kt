package com.dbpprt.dieter.connection

/**
 * Controls how much work Dieter is allowed to do while its Activity is not in
 * the foreground. PERIODIC is deliberately best-effort: Android may defer its
 * one-minute timer while the device is in Doze.
 */
enum class BackgroundSyncMode(val wireValue: String) {
    LIVE("live"),
    PERIODIC("periodic"),
    APP_ONLY("app_only");

    val usesBackgroundService: Boolean
        get() = this != APP_ONLY

    companion object {
        fun resolve(value: String?, legacyEnabled: Boolean = true): BackgroundSyncMode =
            entries.firstOrNull { it.wireValue == value }
                ?: if (legacyEnabled) LIVE else APP_ONLY
    }
}

internal fun backgroundConnectionShouldRun(
    desiredConnected: Boolean,
    appForeground: Boolean,
    serviceActive: Boolean,
    mode: BackgroundSyncMode,
    periodicWindowActive: Boolean,
): Boolean = desiredConnected &&
    (appForeground || serviceActive &&
        (mode == BackgroundSyncMode.LIVE ||
            mode == BackgroundSyncMode.PERIODIC && periodicWindowActive))

internal fun hasActiveBackgroundWork(state: DieterConnectionState): Boolean =
    (state.cards + state.chats).any { isActiveRuntime(it.runtime) } ||
        state.pendingCardIds.isNotEmpty() ||
        state.pendingMessageIds.isNotEmpty() ||
        state.machineOutboxSummaries.values.any { it.itemCount > 0 || it.retrying }
