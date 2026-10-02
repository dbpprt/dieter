package com.dbpprt.dieter.core.quotas

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.core.activity.WidgetModel
import com.dbpprt.dieter.core.presentation.Counts
import kotlin.time.Instant

/** One account of the home-screen usage widget. */
data class UsageWidgetAccount(
    val providerName: String,
    /** The account's [Quotas.identity]. */
    val title: String,
    /** The binding window's remaining percentage, 0-100; null when no window reports one. */
    val remainingPercent: Int?,
    /** The binding window's label and reset time, or [Quotas.STALE] when stale without a reset time. */
    val resetLine: String,
    /** Why an unavailable account cannot be used; it replaces the percentage. Null when available. */
    val availabilityText: String?,
) {
    /** The tint: none for an unavailable account or an unreported percentage. */
    val level: QuotaLevel get() = if (availabilityText != null) QuotaLevel.UNKNOWN else Quotas.level(remainingPercent)
}

/** The most constrained available account, for the small widget's headline. */
data class UsageWidgetLowest(val remainingPercent: Int, val source: String, val resetLine: String)

data class UsageWidgetModel(
    val small: Boolean,
    val summary: String,
    val accounts: List<UsageWidgetAccount>,
    val hiddenAccounts: Int,
    val lowest: UsageWidgetLowest?,
    val statusText: String,
    val emptyTitle: String,
    val emptyBody: String,
) {
    val hasAccounts: Boolean get() = accounts.isNotEmpty() || hiddenAccounts > 0

    /** The headline tint, from the lowest available account. */
    val level: QuotaLevel get() = Quotas.level(lowest?.remainingPercent)
}

/**
 * The home-screen usage widget: one row per provider account, bound to its
 * most constrained window, with the same wording and staleness rule as the
 * app's quota views.
 */
object UsageWidget {
    const val MAX_ACCOUNTS = 6
    const val EMPTY_BODY = "Sign in to a supported provider on a Dieter machine."

    /**
     * [groups] as last fetched; [fetchedTime] is the platform's formatting of
     * that fetch, null before the first one. At most [maxAccounts] rows are
     * shown; the rest are counted.
     */
    fun build(
        groups: List<ProviderQuotaGroup>,
        fetchedTime: String?,
        connected: Boolean,
        small: Boolean,
        now: Instant,
        maxAccounts: Int = MAX_ACCOUNTS,
    ): UsageWidgetModel {
        val rows = groups.flatMap { group -> group.accounts.map { account(group.provider, it, now) } }
        val lowest = rows.filter { it.availabilityText == null }
            .mapNotNull { row -> row.remainingPercent?.let { UsageWidgetLowest(it, row.providerName, row.resetLine) } }
            .minByOrNull { it.remainingPercent }
        val visible = rows.take(maxAccounts.coerceAtLeast(0))
        val count = Counts.of(rows.size, "account")
        return UsageWidgetModel(
            small = small,
            summary = when {
                rows.isEmpty() -> "Provider usage at a glance"
                lowest == null -> count
                else -> "$count · lowest ${lowest.remainingPercent}%"
            },
            accounts = visible,
            hiddenAccounts = rows.size - visible.size,
            lowest = lowest,
            statusText = WidgetModel.status(fetchedTime, connected),
            emptyTitle = if (fetchedTime == null) "No usage yet" else "No provider accounts",
            emptyBody = EMPTY_BODY,
        )
    }

    /** [account]'s row: its binding window is the one with the least remaining, else its first. */
    fun account(provider: ProviderQuotaProvider, account: ProviderQuotaSnapshot, now: Instant): UsageWidgetAccount {
        val binding = account.windows.filter { it.remaining_percent != null }.minByOrNull { it.remaining_percent ?: Int.MAX_VALUE }
            ?: account.windows.firstOrNull()
        val reset = binding?.resets_at?.takeIf(String::isNotBlank)?.let { Quotas.resetText(it, now) }.orEmpty()
        val resetLine = listOfNotNull(
            binding?.label?.takeIf { it.isNotBlank() && it != "Usage" },
            reset.ifEmpty { Quotas.STALE.takeIf { Quotas.stale(account, now) } },
        ).joinToString(" · ")
        return UsageWidgetAccount(
            providerName = Quotas.providerName(provider),
            title = Quotas.identity(account),
            remainingPercent = binding?.remaining_percent?.coerceIn(0, 100),
            resetLine = resetLine,
            availabilityText = if (Quotas.available(account)) null else Quotas.availability(account.availability),
        )
    }
}
