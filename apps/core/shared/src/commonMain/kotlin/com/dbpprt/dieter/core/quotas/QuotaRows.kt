package com.dbpprt.dieter.core.quotas

import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaMachine
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaRefreshState
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.client.v1.QuotaAccountRow
import com.dbpprt.dieter.client.v1.QuotaDetail
import com.dbpprt.dieter.client.v1.QuotaGroupRow
import com.dbpprt.dieter.client.v1.QuotaMachineRow
import com.dbpprt.dieter.client.v1.QuotaSeverity
import com.dbpprt.dieter.client.v1.QuotaWindowRow
import com.dbpprt.dieter.core.runtime.Timestamps

/**
 * Provider quota groups as every view shows them, built from [Quotas]. The
 * rows hold no time-dependent wording: reset times and staleness are worded
 * when rendered.
 */
object QuotaRows {
    fun of(groups: List<ProviderQuotaGroup>): List<QuotaGroupRow> = groups.map(::group)

    fun group(group: ProviderQuotaGroup): QuotaGroupRow = QuotaGroupRow(
        provider = group.provider,
        provider_name = Quotas.providerName(group.provider),
        summary = Quotas.groupSummary(group),
        lowest_remaining = percent(group.summary?.remaining_percent),
        accounts = group.accounts.map { account(group.provider, it) },
    )

    fun account(provider: ProviderQuotaProvider, account: ProviderQuotaSnapshot): QuotaAccountRow {
        val remaining = Quotas.remaining(account)
        val available = Quotas.available(account)
        return QuotaAccountRow(
            account_key = account.account_key,
            label = Quotas.accountLabel(account),
            identity = Quotas.identity(account),
            subtitle = Quotas.subtitle(account),
            remaining = percent(remaining),
            severity = severity(Quotas.level(remaining?.coerceIn(0, 100))),
            available = available,
            unavailable = if (available) "" else Quotas.availability(account.availability),
            status = Quotas.status(account),
            windows = account.windows.map(::window),
            details = Quotas.detailLines(account).map { QuotaDetail(label = it.label, text = it.text, monetary = it.monetary) },
            can_reset = Quotas.canReset(provider, account),
            included = Quotas.included(account),
            fresh_until_millis = Timestamps.parse(account.fresh_until)?.toEpochMilliseconds() ?: 0L,
            summary_line = Quotas.summaryLine(provider, account),
            refreshing = account.refresh_state == ProviderQuotaRefreshState.PROVIDER_QUOTA_REFRESH_STATE_REFRESHING,
            machines = account.machines.map(::machine),
        )
    }

    /** A machine that reported an account: its name, else the start of its ID, and "Online" or "Offline". */
    fun machine(machine: ProviderQuotaMachine): QuotaMachineRow = QuotaMachineRow(
        daemon_id = machine.daemon_id,
        name = machine.name.ifBlank { machine.daemon_id.take(8) },
        online = machine.online,
        state = if (machine.online) "Online" else "Offline",
    )

    fun window(window: ProviderQuotaWindow): QuotaWindowRow = QuotaWindowRow(
        id = window.id,
        name = Quotas.windowName(window),
        remaining = percent(window.remaining_percent),
        severity = severity(Quotas.level(window.remaining_percent?.coerceIn(0, 100))),
        resets_at = window.resets_at,
    )

    fun severity(level: QuotaLevel): QuotaSeverity = when (level) {
        QuotaLevel.CRITICAL -> QuotaSeverity.QUOTA_SEVERITY_CRITICAL
        QuotaLevel.LOW -> QuotaSeverity.QUOTA_SEVERITY_LOW
        QuotaLevel.NORMAL -> QuotaSeverity.QUOTA_SEVERITY_NORMAL
        QuotaLevel.UNKNOWN -> QuotaSeverity.QUOTA_SEVERITY_UNKNOWN
    }

    /** 0-100, or -1 when unreported. */
    private fun percent(value: Int?): Int = value?.coerceIn(0, 100) ?: -1
}
