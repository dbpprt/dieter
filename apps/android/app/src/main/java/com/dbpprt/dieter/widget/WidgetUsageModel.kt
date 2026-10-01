package com.dbpprt.dieter.widget

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.core.quotas.Quotas
import com.dbpprt.dieter.core.runtime.Timestamps
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * One normalized provider account for the usage widget. Built from the
 * gateway's credential-free quota snapshots; identical selection and wording
 * to the Accounts section of the Activity screen.
 */
data class UsageWindowSnapshot(
    val label: String,
    val remainingPercent: Int?,
    val resetsAt: String,
)

data class UsageAccountSnapshot(
    val providerName: String,
    val title: String,
    val available: Boolean,
    val availabilityText: String,
    val freshUntilMs: Long,
    val windows: List<UsageWindowSnapshot>,
)

/** The row rendered for one account: its binding window is the most constrained one. */
data class WidgetUsageAccount(
    val providerName: String,
    val title: String,
    val remainingPercent: Int?,
    val resetLine: String,
    val availabilityText: String?,
)

data class WidgetUsageLowest(
    val remainingPercent: Int,
    val source: String,
    val resetLine: String,
)

data class WidgetUsageModel(
    val small: Boolean,
    val summary: String,
    val accounts: List<WidgetUsageAccount>,
    val hiddenAccounts: Int,
    val lowest: WidgetUsageLowest?,
    val statusText: String,
    val emptyTitle: String,
    val emptyBody: String,
) {
    val hasAccounts: Boolean get() = accounts.isNotEmpty() || hiddenAccounts > 0
}

/** Same binding-window rule as the Activity screen, capped for the home screen. */
fun buildUsageModel(
    snapshots: List<UsageAccountSnapshot>,
    fetchedAtMs: Long,
    connected: Boolean,
    small: Boolean,
    now: Instant = Instant.now(),
    maxAccounts: Int = 6,
): WidgetUsageModel {
    val rows = snapshots.map { it.toRow(now) }
    val lowest = rows.filter { it.availabilityText == null }.mapNotNull { account ->
        account.remainingPercent?.let { percent ->
            WidgetUsageLowest(percent, account.providerName, account.resetLine)
        }
    }.minByOrNull { it.remainingPercent }
    val visible = rows.take(maxAccounts)
    return WidgetUsageModel(
        small = small,
        summary = when {
            rows.isEmpty() -> "Provider usage at a glance"
            lowest == null -> "${rows.size} ${if (rows.size == 1) "account" else "accounts"}"
            else -> "${rows.size} ${if (rows.size == 1) "account" else "accounts"} · lowest ${lowest.remainingPercent}%"
        },
        accounts = visible,
        hiddenAccounts = (rows.size - visible.size).coerceAtLeast(0),
        lowest = lowest,
        statusText = usageStatusText(fetchedAtMs, connected, now),
        emptyTitle = if (fetchedAtMs <= 0) "No usage yet" else "No provider accounts",
        emptyBody = "Sign in to a supported provider on a Dieter machine.",
    )
}

private fun UsageAccountSnapshot.toRow(now: Instant): WidgetUsageAccount {
    val binding = windows.filter { it.remainingPercent != null }.minByOrNull { it.remainingPercent!! }
        ?: windows.firstOrNull()
    val stale = freshUntilMs in 1..now.toEpochMilli()
    val reset = binding?.resetsAt?.takeIf(String::isNotBlank)?.let { Quotas.resetText(it, kotlin.time.Instant.fromEpochMilliseconds(now.toEpochMilli())) }.orEmpty()
    val resetLine = listOfNotNull(
        binding?.label?.takeIf { it.isNotBlank() && it != "Usage" },
        reset.ifEmpty { if (stale) "Last reported · refresh pending" else null },
    ).joinToString(" · ")
    return WidgetUsageAccount(
        providerName = providerName,
        title = title,
        remainingPercent = binding?.remainingPercent,
        resetLine = resetLine,
        // An unavailable account never shows a percentage; the reason replaces it.
        availabilityText = if (available) null else availabilityText,
    )
}

internal fun usageStatusText(fetchedAtMs: Long, connected: Boolean, now: Instant): String {
    if (fetchedAtMs <= 0) return if (connected) "Syncing…" else "Not synced yet"
    // Absolute timestamp stays truthful across hours of host suspension.
    val time = DateTimeFormatter.ofPattern("MMM d, HH:mm").withZone(ZoneId.systemDefault())
        .format(Instant.ofEpochMilli(fetchedAtMs))
    return if (connected) "Updated $time" else "Offline · updated $time"
}

/** Proto → snapshot; wording mirrors the Accounts rows on the Activity screen. */
fun usageSnapshots(groups: List<ProviderQuotaGroup>): List<UsageAccountSnapshot> = groups.flatMap { group ->
    group.accounts.map { account ->
        UsageAccountSnapshot(
            providerName = Quotas.providerName(group.provider),
            title = account.display_email.ifBlank {
                account.plan.ifBlank { "Account" } + " · ••" + account.account_key.takeLast(6)
            },
            available = account.availability == ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
            availabilityText = Quotas.availability(account.availability),
            freshUntilMs = Timestamps.parse(account.fresh_until)?.toEpochMilliseconds() ?: 0L,
            windows = account.windows.map { window ->
                UsageWindowSnapshot(
                    label = window.label,
                    remainingPercent = window.remaining_percent?.coerceIn(0, 100),
                    resetsAt = window.resets_at,
                )
            },
        )
    }
}
