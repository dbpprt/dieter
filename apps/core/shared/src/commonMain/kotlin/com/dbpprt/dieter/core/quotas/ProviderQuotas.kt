package com.dbpprt.dieter.core.quotas

import com.dbpprt.dieter.api.gateway.v1.ConsumeProviderQuotaResetRequest
import com.dbpprt.dieter.api.gateway.v1.GatewayServiceClient
import com.dbpprt.dieter.api.gateway.v1.ListProviderQuotasRequest
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindowKind
import com.dbpprt.dieter.api.gateway.v1.RefreshProviderQuotasRequest
import com.dbpprt.dieter.api.gateway.v1.SetProviderQuotaSummaryInclusionRequest
import com.dbpprt.dieter.api.gateway.v1.WatchProviderQuotasRequest
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.runtime.Backoff
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.runtime.Timestamps
import com.dbpprt.dieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update

data class QuotasView(
    val groups: List<ProviderQuotaGroup> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    /** Accounts with a toggle or reset in flight. */
    val mutating: Set<String> = emptySet(),
    val live: Boolean = false,
)

/**
 * Credential-free provider quota snapshots from the gateway. Every platform
 * watches them (full catalog per frame, 15 s heartbeat) instead of polling.
 * Mutations are deduplicated per account, and a reset reuses one idempotency
 * key for every retry of the same user action. Confined to the core dispatcher.
 */
class ProviderQuotas(private val logger: CoreLogger) {
    private val mutableView = MutableStateFlow(QuotasView())
    val view: StateFlow<QuotasView> = mutableView.asStateFlow()
    private var client: GatewayServiceClient? = null
    private var generation = 0L
    private var readId = 0L
    private val resetKeys = HashMap<String, String>()

    /** Follows the gateway session; without one the last groups stay visible. */
    suspend fun run(gateway: Flow<GatewayServiceClient?>) {
        gateway.collectLatest { next ->
            if (next == null) {
                pause()
                return@collectLatest
            }
            if (client != null && client !== next) reset()
            client = next
            load(refresh = false)
            watch(next)
        }
    }

    private suspend fun watch(gateway: GatewayServiceClient) {
        var attempt = 0
        while (true) {
            try {
                coroutineScope {
                    val call = gateway.WatchProviderQuotas()
                    val frames = call.executeIn(this, WatchProviderQuotasRequest(heartbeat_seconds = HEARTBEAT_SECONDS))
                    try {
                        for (frame in frames) {
                            attempt = 0
                            if (view.value.mutating.isEmpty()) mutableView.update { it.copy(groups = sorted(frame.groups), error = null, live = true) }
                        }
                    } finally {
                        call.cancel()
                    }
                }
                mutableView.update { it.copy(live = false) }
                delay(CLEAN_END_RETRY)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                mutableView.update { it.copy(live = false) }
                logger.debug(TAG, "quota watch ended: ${Failures.message(error)}")
                delay(WATCH_BACKOFF.delay(attempt++))
            }
        }
    }

    /** Reads the catalog; [refresh] asks the machines for new numbers first. */
    suspend fun load(refresh: Boolean) {
        val gateway = client ?: return
        val state = view.value
        if (state.loading || state.mutating.isNotEmpty()) return
        val bound = generation
        val read = ++readId
        mutableView.update { it.copy(loading = true) }
        try {
            val groups = withDeadline(Deadlines.CALL) {
                if (refresh) gateway.RefreshProviderQuotas().execute(RefreshProviderQuotasRequest()).groups
                else gateway.ListProviderQuotas().execute(ListProviderQuotasRequest()).groups
            }
            if (bound == generation && read == readId) mutableView.update { it.copy(groups = sorted(groups), error = null) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == generation && read == readId) mutableView.update { it.copy(error = Failures.message(error).ifEmpty { "Provider quotas are unavailable." }) }
        } finally {
            if (bound == generation && read == readId) mutableView.update { it.copy(loading = false) }
        }
    }

    suspend fun setIncluded(provider: ProviderQuotaProvider, accountKey: String, included: Boolean) = mutate(accountKey, provider) { gateway ->
        gateway.SetProviderQuotaSummaryInclusion().execute(SetProviderQuotaSummaryInclusionRequest(provider = provider, account_key = accountKey, included = included)).groups to true
    }

    /**
     * Uses one OpenAI reset credit. The key is kept until the gateway answers,
     * so a retry of the same action can never consume a second credit.
     */
    suspend fun consumeReset(accountKey: String): Boolean {
        val key = resetKeys.getOrPut(accountKey) { Uuid.random().toString() }
        var accepted = false
        mutate(accountKey, ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX) { gateway ->
            val response = gateway.ConsumeProviderQuotaReset().execute(
                ConsumeProviderQuotaResetRequest(provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, account_key = accountKey, idempotency_key = key),
            )
            resetKeys.remove(accountKey)
            accepted = response.accepted
            response.groups to response.accepted
        }
        if (!accepted) mutableView.update { it.copy(error = "No online machine with access to this OpenAI account accepted the reset.") }
        return accepted
    }

    private suspend fun mutate(accountKey: String, provider: ProviderQuotaProvider, call: suspend (GatewayServiceClient) -> Pair<List<ProviderQuotaGroup>, Boolean>) {
        val gateway = client ?: return
        if (accountKey in view.value.mutating) return
        val bound = generation
        readId++ // A read started before the mutation must not overwrite its result.
        mutableView.update { it.copy(mutating = it.mutating + accountKey, loading = false) }
        try {
            val (groups, _) = withDeadline(Deadlines.CALL) { call(gateway) }
            if (bound == generation) mutableView.update { state -> state.copy(groups = sorted(state.groups.filter { it.provider != provider } + groups), error = null) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == generation) mutableView.update { it.copy(error = Failures.message(error)) }
            throw error
        } finally {
            if (bound == generation) mutableView.update { it.copy(mutating = it.mutating - accountKey) }
        }
    }

    /** Connection lost: keep the last numbers, forget in-flight work. */
    fun pause() {
        generation++
        mutableView.update { it.copy(loading = false, mutating = emptySet(), error = null, live = false) }
    }

    /** Account or gateway changed: forget everything. */
    fun reset() {
        pause()
        client = null
        resetKeys.clear()
        mutableView.value = QuotasView()
    }

    private fun sorted(groups: List<ProviderQuotaGroup>) = groups.sortedBy { it.provider.value }

    companion object {
        const val HEARTBEAT_SECONDS = 15
        private val CLEAN_END_RETRY = 250.milliseconds
        private val WATCH_BACKOFF = Backoff(750.milliseconds, 10.seconds)
        private const val TAG = "Quotas"
    }
}

enum class QuotaLevel { CRITICAL, LOW, NORMAL, UNKNOWN }

/** One row of an account's details; [monetary] rows show a balance or spend, which some views leave out. */
data class QuotaDetailLine(val label: String, val text: String, val monetary: Boolean = false)

/** Quota presentation computed once for every client. */
object Quotas {
    fun included(account: ProviderQuotaSnapshot): Boolean = account.included_in_summary != false

    /** The lowest reported remaining percentage, or null when no window reports one. */
    fun remaining(account: ProviderQuotaSnapshot): Int? = account.windows.mapNotNull { it.remaining_percent }.minOrNull()

    fun level(remaining: Int?): QuotaLevel = when {
        remaining == null -> QuotaLevel.UNKNOWN
        remaining <= 10 -> QuotaLevel.CRITICAL
        remaining <= 30 -> QuotaLevel.LOW
        else -> QuotaLevel.NORMAL
    }

    /** Stale when the account's freshness window has passed or is unknown. */
    fun stale(account: ProviderQuotaSnapshot, now: Instant): Boolean = stale(Timestamps.parse(account.fresh_until), now)

    /** Stale from [freshUntil] on, and always when it is unknown, as the gateway judges it. */
    fun stale(freshUntil: Instant?, now: Instant): Boolean = freshUntil?.let { it <= now } ?: true

    fun available(account: ProviderQuotaSnapshot): Boolean = account.availability == ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE

    fun providerName(provider: ProviderQuotaProvider): String = when (provider) {
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> "OpenAI"
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> "Claude"
        else -> "Provider"
    }

    /** The product the allowance belongs to, for headings. */
    fun productName(provider: ProviderQuotaProvider): String = when (provider) {
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> "OpenAI Codex"
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> "Anthropic Claude"
        else -> "Provider"
    }

    fun maskedKey(account: ProviderQuotaSnapshot): String = "••" + account.account_key.takeLast(6)

    fun plan(account: ProviderQuotaSnapshot): String = account.plan.ifBlank { "Account" }.replaceFirstChar { it.uppercase() }

    /** The account's full identity: its email, else its plan and masked key. */
    fun identity(account: ProviderQuotaSnapshot): String = account.display_email.ifBlank { "${plan(account)} · ${maskedKey(account)}" }

    /** Under the identity: the plan (when the email is shown) and whether the summary excludes it. */
    fun subtitle(account: ProviderQuotaSnapshot): String =
        listOfNotNull(plan(account).takeIf { account.display_email.isNotBlank() }, "Excluded from summary".takeIf { !included(account) })
            .joinToString(" · ").ifBlank { "Account details" }

    /** "2 accounts · 1 excluded". */
    fun groupSummary(group: ProviderQuotaGroup): String = buildString {
        append("${group.accounts.size} account${if (group.accounts.size == 1) "" else "s"}")
        val excluded = group.summary?.excluded_account_count ?: 0
        if (excluded > 0) append(" · $excluded excluded")
    }

    /** Shown instead of windows when none report a limit. */
    fun status(account: ProviderQuotaSnapshot): String = account.status_code.ifBlank { "No numeric limit reported" }.replace('_', ' ')

    /** The warning for numbers that may be out of date. */
    const val STALE = "Last reported · refresh pending"

    /** The confirmation before an account's reset credit is used (only OpenAI accounts have them). */
    const val RESET_TITLE = "Use one OpenAI reset credit?"
    const val RESET_MESSAGE = "This consumes one credit and resets the eligible quota windows for this exact account."

    /** A warning above the windows: unavailable accounts, else stale numbers; null when current. */
    /** [unavailable] (the availability of an unavailable account, else empty) first, then [STALE]; null when current. */
    fun warning(unavailable: String, freshUntil: Instant?, now: Instant): String? = when {
        unavailable.isNotEmpty() -> unavailable
        stale(freshUntil, now) -> STALE
        else -> null
    }

    /** Every detail row of an account, each marked when it shows money. */
    fun detailLines(account: ProviderQuotaSnapshot): List<QuotaDetailLine> = buildList {
        add(QuotaDetailLine("Account", maskedKey(account)))
        account.credits?.let { add(QuotaDetailLine("Credits", if (it.unlimited) "Unlimited" else it.balance.ifBlank { "Available" }, monetary = true)) }
        account.spend_allowance?.let { spend ->
            add(QuotaDetailLine("Spend", listOf(spend.used, spend.limit).filter { it.isNotBlank() }.joinToString(" / ").ifBlank { "Reported" }, monetary = true))
        }
        account.reset_credits?.let { add(QuotaDetailLine("Reset credits", "${it.available_count} available")) }
    }

    /**
     * One line for a tooltip or accessibility label: the provider, the email
     * (else [accountLabel]), and the remaining percentage, or the
     * availability when no window reports one, e.g.
     * "OpenAI · dev@example.com · 45% remaining".
     */
    fun summaryLine(provider: ProviderQuotaProvider, account: ProviderQuotaSnapshot): String {
        val who = account.display_email.ifBlank { accountLabel(account) }
        val state = remaining(account)?.let { "${it.coerceIn(0, 100)}% remaining" } ?: availability(account.availability)
        return "${providerName(provider)} · $who · $state"
    }

    fun availability(value: ProviderQuotaAvailability): String = when (value) {
        ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE -> "Available"
        ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT -> "Signed out"
        ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_UNSUPPORTED -> "Unsupported"
        ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE -> "Unavailable"
        ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_PERMISSION_DENIED -> "Permission denied"
        else -> "Unknown"
    }

    fun windowName(window: ProviderQuotaWindow): String = window.label.ifEmpty {
        when (window.kind) {
            ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_FIVE_HOUR -> "5 hour"
            ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_WEEKLY -> "Weekly"
            ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_MONTHLY -> "Monthly"
            ProviderQuotaWindowKind.PROVIDER_QUOTA_WINDOW_KIND_MODEL -> "Model"
            else -> "Quota"
        }
    }

    /** A short account name: the email's local part, else the plan, else the key's last four characters. */
    fun accountLabel(account: ProviderQuotaSnapshot): String =
        account.display_email.substringBefore('@').ifEmpty { null }
            ?: account.plan.takeIf { it.isNotBlank() }?.replaceFirstChar { it.uppercase() }
            ?: "••" + account.account_key.takeLast(4)

    /** Time until reset: null when unknown, zero or negative when due. */
    fun untilReset(resetsAt: String, now: Instant): Duration? = Timestamps.parse(resetsAt)?.let { it - now }

    /** "Resets in 2h 5m", "Reset due", or "Reset time unavailable". */
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

    /** The account a conversation last ran on, matched by its opaque key only. */
    fun forConversation(card: Card, groups: List<ProviderQuotaGroup>): Pair<ProviderQuotaProvider, ProviderQuotaSnapshot>? {
        if (card.provider_account_key.isEmpty()) return null
        for (group in groups) group.accounts.firstOrNull { it.account_key == card.provider_account_key }?.let { return group.provider to it }
        return null
    }

    /** A reset credit can be used for an OpenAI account that has one. */
    fun canReset(provider: ProviderQuotaProvider, account: ProviderQuotaSnapshot): Boolean =
        provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX && (account.reset_credits?.available_count ?: 0) > 0
}
