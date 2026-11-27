package com.getdieter.core.client.rules

import com.getdieter.client.v1.ProviderSeverity
import com.getdieter.core.providers.OmpAccounts
import com.getdieter.core.providers.ProviderReadiness
import com.getdieter.core.providers.ProviderUsages
import com.getdieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Instant

/**
 * The time-dependent wording of provider rows (`ProvidersSlice`), worded when rendered, and the
 * small rules a sign-in sheet applies while the user types.
 */
object ProviderExports {
    /**
     * "Resets in 2h 30m", "Resets in 1d 2h", "Reset due", or "Reset time unavailable" for an RFC
     * 3339 [resetsAt]; without [fine], only the largest unit ("Resets in 2h").
     */
    fun resetText(resetsAt: String, nowMillis: Long, fine: Boolean): String =
        ProviderUsages.resetText(resetsAt, Instant.fromEpochMilliseconds(nowMillis), fine)

    /** "Updated just now", "Updated 3m ago", or "Not reported yet" for [observedAt]. */
    fun usageUpdated(observedAt: String, nowMillis: Long): String =
        ProviderUsages.updatedText(observedAt, Instant.fromEpochMilliseconds(nowMillis))

    /** The numbers are older than 30 minutes, or were never reported. */
    fun usageStale(observedAt: String, nowMillis: Long): Boolean =
        ProviderUsages.stale(observedAt, Instant.fromEpochMilliseconds(nowMillis))

    /** "62% left" for 0-100; "" for -1 (not reported). */
    fun usageText(remaining: Int): String = ProviderUsages.leftText(remaining)

    /** Critical at 10% or less left, low at 30% or less; unknown for -1. */
    fun severity(remaining: Int): ProviderSeverity = ProviderUsages.severity(remaining)

    /**
     * A device code as the sheet shows it: uppercase, in groups of four joined by "-" unless the
     * provider grouped it already, e.g. "ABCD-EFGH".
     */
    fun deviceCode(code: String): String {
        val trimmed = code.trim().uppercase()
        if ('-' in trimmed || trimmed.isEmpty()) return trimmed
        return trimmed.filterNot { it.isWhitespace() }.chunked(4).joinToString("-")
    }

    /** "Expires in 14:32" (minutes and seconds), "Expires in 1h 5m", "Expired"; "" when unknown. */
    fun codeExpiry(expiresAt: String, nowMillis: Long): String {
        val left =
            Timestamps.parse(expiresAt)?.let { it - Instant.fromEpochMilliseconds(nowMillis) }
                ?: return ""
        if (left <= Duration.ZERO) return "Expired"
        val seconds = left.inWholeSeconds
        return if (seconds >= 3_600) "Expires in ${seconds / 3_600}h ${seconds % 3_600 / 60}m"
        else "Expires in ${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
    }

    /**
     * Why an account cannot run on a machine, from its machine row's [state] (signed_in,
     * signed_out, expired, failed or not_signed_in): "Not signed in on box", "Sign-in expired on
     * box", "box is offline"; "" when it can.
     */
    fun readinessReason(state: String, machine: String, online: Boolean): String =
        ProviderReadiness.reason(state, online, machine)

    /** The confirmation before a reset credit is spent: "Use one ChatGPT reset credit?". */
    fun resetTitle(): String = ProviderUsages.RESET_TITLE

    fun resetMessage(): String = ProviderUsages.RESET_MESSAGE

    /**
     * The switch a Claude account row offers (`offers_omp_access`): "Allow Oh My Pi to use this
     * login", with [ompAccessDetail] under it.
     */
    fun ompAccessLabel(): String = OmpAccounts.ACCESS_LABEL

    fun ompAccessDetail(): String = OmpAccounts.ACCESS_DETAIL

    /**
     * The confirmation before the switch turns on, with [ompAccessConfirm] as its button; turning
     * it off needs none.
     */
    fun ompAccessTitle(): String = OmpAccounts.ACCESS_TITLE

    fun ompAccessMessage(): String = OmpAccounts.ACCESS_MESSAGE

    fun ompAccessConfirm(): String = OmpAccounts.ACCESS_CONFIRM
}
