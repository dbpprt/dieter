package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.GlobalDelta

internal const val SYNC_PROJECTION_PERSIST_INTERVAL_MS = 15_000L

internal fun GlobalDelta.changesProjection(): Boolean =
    projectsCount > 0 || removedProjectIdsCount > 0 ||
        boardsCount > 0 || removedBoardIdsCount > 0 ||
        cardsCount > 0 || removedCardIdsCount > 0 ||
        chatsCount > 0 || removedChatIdsCount > 0 ||
        schedulesCount > 0 || removedScheduleIdsCount > 0 ||
        scheduleRunsCount > 0 || removedScheduleRunIdsCount > 0 ||
        hasSettings() ||
        conversationsCount > 0 || removedConversationIdsCount > 0

internal fun syncProjectionShouldPersist(lastPersistedAtMillis: Long?, nowMillis: Long): Boolean =
    lastPersistedAtMillis == null || nowMillis - lastPersistedAtMillis >= SYNC_PROJECTION_PERSIST_INTERVAL_MS
