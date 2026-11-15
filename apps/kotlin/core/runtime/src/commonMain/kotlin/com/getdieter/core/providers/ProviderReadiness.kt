package com.getdieter.core.providers

import com.getdieter.client.v1.AgentAccountOption
import com.getdieter.client.v1.ProviderNotice
import com.getdieter.client.v1.ProvidersSlice

/** Whether an account can run turns on a machine now. */
enum class Readiness {
    READY,
    SIGNED_OUT,
    EXPIRED,
    MACHINE_OFFLINE,
    NO_ACCOUNT,
}

data class AccountReadiness(val readiness: Readiness, val reason: String = "") {
    val ready: Boolean
        get() = readiness == Readiness.READY
}

/** One account an agent picker offers, with its readiness on the picker's target machine. */
data class AccountChoice(
    val id: String,
    val label: String,
    /** "alice@corp.com · Max". */
    val detail: String = "",
    val readiness: AccountReadiness = AccountReadiness(Readiness.READY),
    val isDefault: Boolean = false,
) {
    val ready: Boolean
        get() = readiness.ready
}

/**
 * The accounts agent pickers offer per provider, judged on one machine ([daemonId], empty when none
 * is chosen yet), and the account a conversation last ran on ([last]).
 */
data class AgentAccounts(
    val byProvider: Map<String, List<AccountChoice>> = emptyMap(),
    val last: String = "",
    val daemonId: String = "",
    val machine: String = "",
)

/**
 * The readiness rule every client shares with the daemons: an account is ready on machine M when
 * M's login record for it exists and is signed in.
 */
object ProviderReadiness {
    /** [accountId] on [daemonId] in [view]; any machine when [daemonId] is empty. */
    fun of(view: ProvidersView, accountId: String, daemonId: String): AccountReadiness {
        val account = view.account(accountId) ?: return noAccount()
        if (daemonId.isEmpty()) return anywhere(account.logins.values.any { it.signedIn })
        val machine = view.machine(daemonId)
        return evaluate(
            state = account.logins[daemonId]?.state,
            online = machine?.online ?: false,
            machine = view.machineName(daemonId),
        )
    }

    /**
     * Ready when [state] is signed_in; an expired sign-in says so; a machine that is offline says
     * that before "not signed in", since nobody can sign in there now.
     */
    fun evaluate(state: String?, online: Boolean, machine: String): AccountReadiness =
        when (state) {
            ProviderKinds.SIGNED_IN -> AccountReadiness(Readiness.READY)
            ProviderKinds.EXPIRED ->
                AccountReadiness(Readiness.EXPIRED, "Sign-in expired on $machine")
            else ->
                if (!online) AccountReadiness(Readiness.MACHINE_OFFLINE, "$machine is offline")
                else AccountReadiness(Readiness.SIGNED_OUT, "Not signed in on $machine")
        }

    /** The reason text of a slice machine row ([ProviderMachineRow.state]). */
    fun reason(state: String, online: Boolean, machine: String): String =
        evaluate(state, online, machine).reason

    fun noAccount(): AccountReadiness =
        AccountReadiness(Readiness.NO_ACCOUNT, "This account is no longer available")

    private fun anywhere(signedIn: Boolean): AccountReadiness =
        if (signedIn) AccountReadiness(Readiness.READY)
        else AccountReadiness(Readiness.SIGNED_OUT, "Not signed in on any machine")
}

/** Agent pickers' accounts and the conversation notice built from them. */
object AgentAccountRules {
    /**
     * [view]'s accounts judged on [daemonId] (empty: none chosen yet); [last] for conversations.
     */
    fun forMachine(view: ProvidersView, daemonId: String?, last: String = ""): AgentAccounts {
        val target = daemonId.orEmpty()
        return AgentAccounts(
            byProvider =
                view.accounts
                    .groupBy { it.provider }
                    .mapValues { (_, accounts) ->
                        accounts.map { account ->
                            AccountChoice(
                                id = account.id,
                                label = account.label,
                                detail = detail(account.identity.email, account.plan),
                                readiness = ProviderReadiness.of(view, account.id, target),
                                isDefault = account.isDefault,
                            )
                        }
                    },
            last = last,
            daemonId = target,
            machine = if (target.isEmpty()) "" else view.machineName(target),
        )
    }

    /**
     * The accounts a [slice] lists, judged on [daemonId] from its machine rows, for forms that keep
     * their own selection outside the core.
     */
    fun fromSlice(slice: ProvidersSlice, daemonId: String): AgentAccounts {
        var machineName = ""
        val byProvider =
            slice.groups.associate { group ->
                group.provider to
                    group.accounts.map { row ->
                        val machine = row.machines.firstOrNull { it.daemon_id == daemonId }
                        if (machine != null) machineName = machine.name
                        val readiness =
                            when {
                                daemonId.isEmpty() ->
                                    if (row.machines.any { it.state == ProviderKinds.SIGNED_IN })
                                        AccountReadiness(Readiness.READY)
                                    else
                                        AccountReadiness(
                                            Readiness.SIGNED_OUT,
                                            "Not signed in on any machine",
                                        )
                                else ->
                                    ProviderReadiness.evaluate(
                                        machine?.state,
                                        machine?.online ?: false,
                                        machine?.name?.ifBlank { null } ?: daemonId.take(8),
                                    )
                            }
                        AccountChoice(
                            id = row.id,
                            label = row.label,
                            detail =
                                detail(
                                    row.identity.takeIf { '@' in it }.orEmpty(),
                                    // The subtitle starts with the plan when one is known.
                                    row.subtitle.substringBefore(" · ", ""),
                                ),
                            readiness = readiness,
                            isDefault = row.is_default,
                        )
                    }
            }
        return AgentAccounts(byProvider, daemonId = daemonId, machine = machineName)
    }

    /** "alice@corp.com · Max"; "Not signed in yet" without either. */
    fun detail(email: String, plan: String): String =
        listOf(email, ProviderKinds.planName(plan))
            .filter { it.isNotBlank() }
            .joinToString(" · ")
            .ifEmpty { "Not signed in yet" }

    fun option(choice: AccountChoice): AgentAccountOption =
        AgentAccountOption(
            id = choice.id,
            label = choice.label,
            detail = choice.detail,
            ready = choice.ready,
            reason = choice.readiness.reason,
            is_default = choice.isDefault,
        )

    /**
     * The conversation banner when the account a send would use cannot run on the conversation's
     * machine: sign in there, sign in again after an expiry, or choose another account.
     */
    fun notice(
        account: AccountChoice?,
        missingId: String?,
        accounts: AgentAccounts,
    ): ProviderNotice? {
        if (missingId != null)
            return ProviderNotice(
                account_id = missingId,
                daemon_id = accounts.daemonId,
                machine = accounts.machine,
                title = "The chosen account is no longer available",
                action = ACTION_CHOOSE_ACCOUNT,
            )
        account ?: return null
        if (account.ready || accounts.daemonId.isEmpty()) return null
        val machine = accounts.machine.ifEmpty { accounts.daemonId.take(8) }
        val (title, action) =
            when (account.readiness.readiness) {
                Readiness.EXPIRED ->
                    "${account.label}'s sign-in expired on $machine" to ACTION_SIGN_IN_AGAIN
                Readiness.SIGNED_OUT ->
                    "${account.label} isn't signed in on $machine" to ACTION_SIGN_IN
                else -> "${account.label} isn't signed in on $machine" to ACTION_CHOOSE_ACCOUNT
            }
        return ProviderNotice(
            account_id = account.id,
            account_label = account.label,
            daemon_id = accounts.daemonId,
            machine = machine,
            title = title,
            action = action,
        )
    }

    const val ACTION_SIGN_IN = "sign_in"
    const val ACTION_SIGN_IN_AGAIN = "sign_in_again"
    const val ACTION_CHOOSE_ACCOUNT = "choose_account"
}
