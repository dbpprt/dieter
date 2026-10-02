package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.QuotaGroupList
import com.dbpprt.dieter.client.v1.QuotaGroupRows
import com.dbpprt.dieter.core.quotas.QuotaRows
import com.dbpprt.dieter.core.quotas.Quotas
import kotlin.time.Instant

/**
 * The time-dependent parts of provider quota rows (`QuotasSlice.group_rows`),
 * worded when rendered, and the rows for groups the core does not watch,
 * e.g. a fixture's.
 */
object QuotaExports {
    /** [groups] as `QuotasSlice.group_rows` shows them, in the same order. */
    fun rows(groups: QuotaGroupList): QuotaGroupRows = QuotaGroupRows(QuotaRows.of(groups.groups))

    /**
     * "Resets in 2h 30m", "Resets in 1d 2h", "Reset due", or "Reset time
     * unavailable" for an RFC 3339 [resetsAt]; without [fine], only the
     * largest unit ("Resets in 2h").
     */
    fun resetText(resetsAt: String, nowMillis: Long, fine: Boolean): String =
        Quotas.resetText(resetsAt, Instant.fromEpochMilliseconds(nowMillis), fine)

    /**
     * The warning above an account's windows: [unavailable] (the row's
     * reason, empty when available), else "Last reported · refresh pending"
     * when stale; "" when current.
     */
    fun warning(unavailable: String, freshUntilMillis: Long, nowMillis: Long): String =
        Quotas.warning(unavailable, FormatExports.instant(freshUntilMillis), Instant.fromEpochMilliseconds(nowMillis)).orEmpty()
}
