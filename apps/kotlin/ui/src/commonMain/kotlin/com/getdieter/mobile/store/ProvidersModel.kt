package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The Claude and ChatGPT accounts agent turns run on: their sign-ins on each machine, usage and
 * this device's sign-in sessions. The core words and decides everything; this holder observes its
 * slice while some view shows it ([show]) and sends its commands.
 */
class ProvidersModel internal constructor(private val context: StoreContext) {
    val slice = MutableStateFlow(ProvidersSlice())

    /**
     * The last reset credit's outcome, e.g. "Usage limits were reset."; null until one is spent.
     */
    val reset = MutableStateFlow<ProviderResetOutcome?>(null)
    private var viewers = 0
    private var subscription: ClientSubscription? = null

    /**
     * Observes the providers while a view shows them; call the returned function when it leaves.
     */
    fun show(): () -> Unit {
        if (context.closed) return {}
        if (viewers++ == 0)
            subscription =
                context.observe(Slice.SLICE_PROVIDERS, "") { update ->
                    update.providers?.let { slice.value = it }
                }
        var released = false
        return {
            if (!released) {
                released = true
                if (--viewers == 0) {
                    subscription?.close()
                    subscription = null
                }
            }
        }
    }

    /**
     * Adds a [provider] account named [label]; an empty [method] takes the provider's default.
     * [created] gets the new account's ID, [failed] the reason it was not added.
     */
    fun create(
        provider: String,
        label: String,
        method: String,
        failed: (String) -> Unit = {},
        created: (String) -> Unit,
    ) = context.action {
        val result =
            reporting(failed) {
                dispatch(ProvidersCommand(create = ProviderCreate(provider, label.trim(), method)))
            }
        result.provider_account?.account_id?.takeIf { it.isNotEmpty() }?.let(created)
    }

    fun rename(accountId: String, label: String) =
        command(ProvidersCommand(rename = ProviderRename(accountId, label.trim())))

    /** Every machine signs the account out and forgets it. */
    fun remove(accountId: String) =
        command(ProvidersCommand(remove = ProviderAccountRef(accountId)))

    fun setDefault(accountId: String) =
        command(ProvidersCommand(set_default = ProviderAccountRef(accountId)))

    fun setIncluded(accountId: String, included: Boolean) =
        command(ProvidersCommand(set_included = ProviderInclusion(accountId, included)))

    /**
     * Signs [accountId] in on [daemonId]; [started] gets the session the sign-in sheet follows in
     * [ProvidersSlice.sessions], [failed] the reason it did not start.
     */
    fun signIn(
        accountId: String,
        daemonId: String,
        failed: (String) -> Unit = {},
        started: (String) -> Unit,
    ) = context.action {
        reporting(failed) {
                dispatch(ProvidersCommand(sign_in = ProviderSignInStart(accountId, daemonId)))
            }
            .provider_sign_in
            ?.session_id
            ?.takeIf { it.isNotEmpty() }
            ?.let(started)
    }

    /** One session that signs [accountId] in on every online machine without a sign-in. */
    fun signInAll(accountId: String, started: (String) -> Unit) = context.action {
        dispatch(ProvidersCommand(sign_in_all = ProviderAccountRef(accountId)))
            .provider_sign_in
            ?.session_id
            ?.takeIf { it.isNotEmpty() }
            ?.let(started)
    }

    /** Hands the code the provider showed to session [sessionId]. */
    fun submitCode(sessionId: String, code: String) =
        command(ProvidersCommand(submit = ProviderSignInInput(sessionId, code = code.trim())))

    /** Hands the loopback address the browser could not open to session [sessionId]. */
    fun submitCallback(sessionId: String, url: String) =
        command(
            ProvidersCommand(submit = ProviderSignInInput(sessionId, callback_url = url.trim()))
        )

    fun cancel(sessionId: String) =
        command(ProvidersCommand(cancel = ProviderSessionRef(sessionId)))

    /** Drops session [sessionId] from the slice; a live one is canceled first. */
    fun dismiss(sessionId: String) =
        command(ProvidersCommand(dismiss = ProviderSessionRef(sessionId)))

    fun signOut(accountId: String, daemonId: String) =
        command(ProvidersCommand(sign_out = ProviderMachineRef(accountId, daemonId)))

    fun check(accountId: String, daemonId: String) =
        command(ProvidersCommand(check = ProviderMachineRef(accountId, daemonId)))

    fun refreshUsage(accountId: String) =
        command(ProvidersCommand(refresh_usage = ProviderAccountRef(accountId)))

    /** Spends one of [accountId]'s ChatGPT reset credits; [reset] shows the outcome. */
    fun consumeReset(accountId: String) = context.action {
        dispatch(ProvidersCommand(consume_reset = ProviderAccountRef(accountId)))
            .provider_reset
            ?.let { reset.value = it }
    }

    private suspend fun dispatch(value: ProvidersCommand) =
        context.core.dispatch(Command(providers = value))

    /** Runs [block]; a failure also reaches [failed] before the store shows it. */
    private suspend fun <T> reporting(failed: (String) -> Unit, block: suspend () -> T): T =
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            failed(failure.message ?: "The action failed.")
            throw failure
        }

    private fun command(value: ProvidersCommand) = context.command(Command(providers = value))

    internal fun release() {
        subscription?.close()
        subscription = null
    }
}
