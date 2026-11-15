package com.getdieter.core.providers

import com.getdieter.client.v1.ProviderAccountRow
import com.getdieter.client.v1.ProviderGroupRow
import com.getdieter.client.v1.ProviderMachineRow
import com.getdieter.client.v1.ProviderSignInSession
import com.getdieter.client.v1.ProviderWindowRow
import com.getdieter.client.v1.ProvidersSlice
import com.getdieter.core.presentation.Ages
import com.getdieter.core.presentation.Counts
import com.getdieter.core.runtime.Timestamps
import kotlin.time.Instant

/** [ProvidersView] as every client shows it (SLICE_PROVIDERS). */
object ProvidersPresenter {
    fun slice(view: ProvidersView, now: Instant): ProvidersSlice =
        ProvidersSlice(
            groups = ProviderKinds.ALL.map { group(view, it, now) },
            summary = ProviderUsages.summary(view.accounts),
            sessions = view.sessions.map { session(view, it) },
            mutating = view.mutating.sorted(),
            error = view.error.orEmpty(),
        )

    /** One provider's accounts; Claude and ChatGPT always show, so either can add one. */
    fun group(view: ProvidersView, provider: String, now: Instant): ProviderGroupRow {
        val accounts = view.accounts(provider)
        val excluded = accounts.count { !it.includeInSummary }
        return ProviderGroupRow(
            provider = provider,
            provider_name = ProviderKinds.name(provider),
            summary =
                if (accounts.isEmpty()) "No accounts"
                else
                    Counts.of(accounts.size, "account") +
                        (if (excluded > 0) " · $excluded excluded" else ""),
            default_account_id = accounts.firstOrNull { it.isDefault }?.id.orEmpty(),
            accounts = accounts.map { account(view, it, now) },
        )
    }

    fun account(
        view: ProvidersView,
        account: ProviderAccountView,
        now: Instant,
    ): ProviderAccountRow {
        val usage = account.usage
        val remaining = ProviderUsages.remaining(usage)
        val signs = ProviderKinds.signsIn(account.method)
        val busy = view.sessions.filter { it.accountId == account.id && !it.finished }
        val credits = usage?.resetCredits ?: 0
        val provider = ProviderKinds.name(account.provider)
        return ProviderAccountRow(
            id = account.id,
            label = account.label,
            identity = account.identity.email.ifEmpty { "Not signed in yet" },
            subtitle =
                listOf(
                        ProviderKinds.planName(account.plan),
                        ProviderKinds.methodLabel(account.method),
                    )
                    .filter { it.isNotBlank() }
                    .joinToString(" · "),
            method = account.method,
            is_default = account.isDefault,
            included = account.includeInSummary,
            remaining = remaining ?: -1,
            severity = ProviderUsages.severity(remaining),
            summary_line =
                "$provider · ${account.label} · " +
                    ProviderUsages.leftText(remaining).ifEmpty {
                        if (account.logins.values.none { it.signedIn }) "Not signed in"
                        else ProviderUsages.status(usage)
                    },
            windows =
                usage?.windows.orEmpty().mapIndexed { index, window ->
                    val left = ProviderUsages.remaining(window)
                    ProviderWindowRow(
                        id = windowId(usage!!.windows, index),
                        name = ProviderUsages.windowName(window),
                        remaining = left ?: -1,
                        severity = ProviderUsages.severity(left),
                        resets_at = window.resetsAt,
                    )
                },
            usage_observed_at = usage?.observedAt.orEmpty(),
            dieter_tokens = ProviderUsages.tokensText(account.tokens),
            machines = view.machines.map { machine(account, it, busy, now) },
            can_reset =
                account.provider == ProviderKinds.CHATGPT &&
                    credits > 0 &&
                    view.reachable.any { account.signedIn(it.id) },
            reset_label = if (credits > 0) ProviderUsages.resetLabel(credits) else "",
            manage_usage_url = ProviderUsages.manageUsageUrl(account.provider),
            can_sign_in_all =
                signs && view.reachable.any { !account.signedIn(it.id) } && busy.isEmpty(),
            status = if (usage?.windows.isNullOrEmpty()) ProviderUsages.status(usage) else "",
            managed = !signs,
        )
    }

    fun machine(
        account: ProviderAccountView,
        machine: ProviderMachine,
        sessions: List<SignInSession>,
        now: Instant,
    ): ProviderMachineRow {
        val login = account.logins[machine.id]
        val state = login?.state ?: ProviderKinds.NOT_SIGNED_IN
        val signs = ProviderKinds.signsIn(account.method)
        val signingIn = sessions.any { it.daemonId == machine.id }
        return ProviderMachineRow(
            daemon_id = machine.id,
            name = machine.name,
            online = machine.online,
            state = state,
            state_label = stateLabel(state),
            detail = detail(login, now),
            can_sign_in = signs && machine.reachable && login?.signedIn != true && !signingIn,
            can_sign_out = signs && machine.reachable && login?.signedIn == true,
            can_check = machine.reachable && login != null,
        )
    }

    /** "Signed in", "Not signed in", "Sign-in expired", ... */
    fun stateLabel(state: String): String =
        when (state) {
            ProviderKinds.SIGNED_IN -> "Signed in"
            ProviderKinds.SIGNED_OUT -> "Signed out"
            ProviderKinds.EXPIRED -> "Sign-in expired"
            ProviderKinds.FAILED -> "Sign-in failed"
            else -> "Not signed in"
        }

    /** "alice@corp.com · verified 2m ago", or the machine's error. */
    fun detail(login: LoginRecord?, now: Instant): String {
        login ?: return ""
        if (!login.signedIn && (login.errorMessage.isNotEmpty() || login.errorCode.isNotEmpty()))
            return login.errorMessage.ifEmpty { login.errorCode.replace('_', ' ') }
        val verified = Timestamps.parse(login.verifiedAt)?.let { "verified ${Ages.ago(it, now)}" }
        return listOfNotNull(login.identity.email.ifEmpty { null }, verified).joinToString(" · ")
    }

    fun session(view: ProvidersView, session: SignInSession): ProviderSignInSession {
        val account = view.account(session.accountId)
        val machine = view.machineName(session.daemonId)
        val challenge = session.challenge
        val expects = SignInPhases.expects(challenge?.expects)
        val sameHost = view.local?.id == session.daemonId
        return ProviderSignInSession(
            id = session.id,
            account_id = session.accountId,
            account_label = account?.label.orEmpty(),
            daemon_id = session.daemonId,
            machine = machine,
            title = title(account, machine),
            phase = session.phase,
            open_url = challenge?.open_url.orEmpty(),
            local_url = challenge?.local_url.orEmpty(),
            same_host = sameHost,
            callback_port = challenge?.callback_port ?: 0,
            user_code = challenge?.user_code.orEmpty(),
            expires_at = challenge?.expires_at.orEmpty(),
            expects = expects,
            error = session.error,
            remaining_machines = session.remaining.size,
            instructions = instructions(account, session, expects, sameHost, machine),
        )
    }

    /**
     * "Sign in to Claude Code on box", "Sign in to Codex on box", "Sign in with ChatGPT on box".
     */
    fun title(account: ProviderAccountView?, machine: String): String =
        when {
            account?.method == ProviderKinds.METHOD_SIWC -> "Sign in with ChatGPT on $machine"
            account?.provider == ProviderKinds.CHATGPT -> "Sign in to Codex on $machine"
            else -> "Sign in to Claude Code on $machine"
        }

    /** One line for the sheet: what to do now. */
    fun instructions(
        account: ProviderAccountView?,
        session: SignInSession,
        expects: String,
        sameHost: Boolean,
        machine: String,
    ): String {
        val company = if (account?.provider == ProviderKinds.CHATGPT) "OpenAI" else "Anthropic"
        return when (session.phase) {
            SignInPhases.STARTING -> "Starting the sign-in on $machine…"
            SignInPhases.COMPLETING -> "Finishing the sign-in on $machine…"
            SignInPhases.SUCCEEDED ->
                if (session.email.isNotEmpty()) "Signed in as ${session.email} on $machine"
                else "Signed in on $machine"
            SignInPhases.FAILED -> session.error.ifEmpty { "The sign-in failed." }
            SignInPhases.CANCELED -> "The sign-in was canceled."
            else ->
                when (expects) {
                    "code" -> "Paste the code $company shows you"
                    "none" -> "Open the page and enter this code"
                    "callback" ->
                        if (sameHost) "Finish signing in in your browser"
                        else "Sign in, then paste the address your browser couldn't open"
                    else -> "Open the sign-in page to continue"
                }
        }
    }

    /** A window's kind, numbered when the provider reports several of one kind. */
    private fun windowId(windows: List<UsageWindowRecord>, index: Int): String {
        val kind = windows[index].kind.ifEmpty { "other" }
        return if (windows.count { it.kind.ifEmpty { "other" } == kind } == 1) kind
        else "$kind-$index"
    }
}
