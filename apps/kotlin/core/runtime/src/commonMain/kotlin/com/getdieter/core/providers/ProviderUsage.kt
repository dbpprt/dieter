package com.getdieter.core.providers

import com.getdieter.client.v1.ProviderSeverity
import com.getdieter.client.v1.ProviderSummary
import com.getdieter.client.v1.ProviderSummaryItem
import com.getdieter.core.presentation.Ages
import com.getdieter.core.presentation.TokenCounts
import com.getdieter.core.runtime.Timestamps
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/**
 * Plan usage of provider accounts, worded once for every client. An account's usage is the freshest
 * any of its machines observed; Dieter's own token counts add up over machines.
 */
object ProviderUsages {
    /** Numbers older than this read as possibly out of date. */
    val STALE_AFTER: Duration = 30.minutes

    /** The usage with the newest observation time; unknown times lose to known ones. */
    fun freshest(logins: Collection<LoginRecord>): UsageRecord? =
        logins
            .mapNotNull { it.usage }
            .maxWithOrNull { a, b -> Timestamps.compare(a.observedAt, b.observedAt) }

    /** Dieter's own tokens summed over [logins]; null when none reports any. */
    fun tokens(logins: Collection<LoginRecord>): TokenRecord? =
        logins
            .mapNotNull { it.tokens }
            .reduceOrNull { a, b ->
                TokenRecord(
                    fiveHour = a.fiveHour + b.fiveHour,
                    sevenDay = a.sevenDay + b.sevenDay,
                    observedAt =
                        if (Timestamps.compare(a.observedAt, b.observedAt) >= 0) a.observedAt
                        else b.observedAt,
                )
            }

    /** 0-100 left in [window], rounded down; null when the provider left it out. */
    fun remaining(window: UsageWindowRecord): Int? =
        window.usedPercent?.let { (100.0 - it).coerceIn(0.0, 100.0).toInt() }

    /** What is left of the tightest window: 100 minus the highest use; null without numbers. */
    fun remaining(usage: UsageRecord?): Int? =
        usage?.windows.orEmpty().mapNotNull(::remaining).minOrNull()

    /** Critical at 10% or less left, low at 30% or less. */
    fun severity(remaining: Int?): ProviderSeverity =
        when {
            remaining == null || remaining < 0 -> ProviderSeverity.PROVIDER_SEVERITY_UNKNOWN
            remaining <= 10 -> ProviderSeverity.PROVIDER_SEVERITY_CRITICAL
            remaining <= 30 -> ProviderSeverity.PROVIDER_SEVERITY_LOW
            else -> ProviderSeverity.PROVIDER_SEVERITY_NORMAL
        }

    /** "62% left"; "" when unknown. */
    fun leftText(remaining: Int?): String =
        remaining?.takeIf { it >= 0 }?.let { "${it.coerceAtMost(100)}% left" }.orEmpty()

    /** "Claude 62% left"; "" when unknown. */
    fun providerText(provider: String, remaining: Int?): String =
        leftText(remaining)
            .takeIf { it.isNotEmpty() }
            ?.let { "${ProviderKinds.name(provider)} $it" }
            .orEmpty()

    /** Older than [STALE_AFTER], or never observed. */
    fun stale(observedAt: String, now: Instant): Boolean =
        Timestamps.parse(observedAt)?.let { now - it > STALE_AFTER } ?: true

    /** "Updated just now", "Updated 3m ago"; "Not reported yet" when never observed. */
    fun updatedText(observedAt: String, now: Instant): String =
        Timestamps.parse(observedAt)?.let { "Updated ${Ages.ago(it, now)}" } ?: "Not reported yet"

    /** "5 hour", "Weekly", "Model", or the provider's own label. */
    fun windowName(window: UsageWindowRecord): String =
        window.label.ifBlank {
            when (window.kind) {
                "five_hour" -> "5 hour"
                "weekly" -> "Weekly"
                "model" -> "Model"
                else -> "Usage"
            }
        }

    /** Time until reset: null when unknown, zero or negative when due. */
    fun untilReset(resetsAt: String, now: Instant): Duration? =
        Timestamps.parse(resetsAt)?.let { it - now }

    /**
     * "Resets in 2h 5m", "Resets in 1d 2h", "Reset due", or "Reset time unavailable"; without
     * [fine], only the largest unit ("Resets in 2h").
     */
    fun resetText(resetsAt: String, now: Instant, fine: Boolean = true): String {
        val left = untilReset(resetsAt, now) ?: return "Reset time unavailable"
        if (left <= Duration.ZERO) return "Reset due"
        val days = left.inWholeDays
        val hours = left.inWholeHours % 24
        val minutes = maxOf(1, left.inWholeMinutes % 60)
        return when {
            !fine && days > 0 -> "Resets in ${days}d"
            !fine && left.inWholeHours > 0 -> "Resets in ${left.inWholeHours}h"
            !fine -> "Resets in ${maxOf(1, left.inWholeMinutes)}m"
            days > 0 -> "Resets in ${days}d ${hours}h"
            left.inWholeHours > 0 -> "Resets in ${left.inWholeHours}h ${left.inWholeMinutes % 60}m"
            else -> "Resets in ${minutes}m"
        }
    }

    /** "1.2M tokens in 5 h · 8.4M in 7 days"; "" when Dieter's turns used none. */
    fun tokensText(tokens: TokenRecord?): String {
        tokens ?: return ""
        if (tokens.fiveHour.total <= 0 && tokens.sevenDay.total <= 0) return ""
        return "${TokenCounts.compact(tokens.fiveHour.total)} tokens in 5 h · " +
            "${TokenCounts.compact(tokens.sevenDay.total)} in 7 days"
    }

    /** Why no windows show, e.g. "Usage not reported". */
    fun status(usage: UsageRecord?): String =
        when (usage?.unavailable.orEmpty()) {
            "signed_out" -> "Not signed in"
            "unsupported" -> "Usage is not available for this plan"
            "rate_limited" -> "Usage temporarily unavailable"
            else -> "Usage not reported"
        }

    /**
     * The header summary over accounts counted in summaries: per provider its tightest account, and
     * overall the tightest provider ("62% left").
     */
    fun summary(accounts: List<ProviderAccountView>): ProviderSummary {
        val items =
            ProviderKinds.ALL.mapNotNull { provider ->
                val included = accounts.filter { it.provider == provider && it.includeInSummary }
                if (included.isEmpty()) return@mapNotNull null
                val tightest =
                    included
                        .mapNotNull { account -> remaining(account.usage)?.let { account to it } }
                        .minByOrNull { it.second }
                val remaining = tightest?.second
                ProviderSummaryItem(
                    provider = provider,
                    provider_name = ProviderKinds.name(provider),
                    remaining = remaining ?: -1,
                    severity = severity(remaining),
                    text = providerText(provider, remaining),
                    account_id = tightest?.first?.id.orEmpty(),
                )
            }
        val tightest = items.filter { it.remaining >= 0 }.minByOrNull { it.remaining }
        return ProviderSummary(
            items = items,
            text = leftText(tightest?.remaining),
            severity = tightest?.severity ?: ProviderSeverity.PROVIDER_SEVERITY_UNKNOWN,
        )
    }

    /** "Reset usage limits (1 credit)". */
    fun resetLabel(credits: Int): String =
        "Reset usage limits ($credits credit${if (credits == 1) "" else "s"})"

    const val RESET_TITLE = "Use one ChatGPT reset credit?"
    const val RESET_MESSAGE =
        "This spends one credit and resets the usage limits of this ChatGPT account now."

    /** What a reset outcome means, for the result and a toast. */
    fun resetMessage(outcome: String): String =
        when (outcome) {
            "reset" -> "Usage limits were reset."
            "nothingToReset" -> "Nothing to reset: no usage limit is reached."
            "noCredit" -> "This account has no reset credit left."
            "alreadyRedeemed" -> "This reset was already used."
            else -> "The reset finished: $outcome."
        }

    /** The provider's own usage page. */
    fun manageUsageUrl(provider: String): String =
        when (provider) {
            ProviderKinds.CLAUDE -> "https://claude.ai/settings/usage"
            ProviderKinds.CHATGPT -> "https://chatgpt.com/settings/usage"
            else -> ""
        }
}
