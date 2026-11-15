package com.getdieter.core.providers

import com.getdieter.api.v1.CancelProviderLoginRequest
import com.getdieter.api.v1.ProviderLogin
import com.getdieter.api.v1.ProviderLoginChallenge
import com.getdieter.api.v1.ProviderLoginFlow
import com.getdieter.api.v1.ProviderLoginInput
import com.getdieter.api.v1.ProviderLoginPhase
import com.getdieter.api.v1.StartProviderLoginRequest
import com.getdieter.api.v1.SubmitProviderLoginInputRequest
import com.getdieter.api.v1.WatchProviderLoginRequest
import com.getdieter.core.runtime.Backoff
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.withDeadline
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One sign-in of this device: an account signing in on a machine, live or finished. */
data class SignInSession(
    val id: String,
    val accountId: String,
    /** The machine that signs in now. */
    val daemonId: String,
    /** paste_code, device_code, browser, or empty for the method's default. */
    val flow: String = "",
    /** The daemon's login, once it started. */
    val loginId: String = "",
    /** starting, waiting, completing, succeeded, failed or canceled. */
    val phase: String = SignInPhases.STARTING,
    /** The latest challenge; a device code refresh replaces it. */
    val challenge: ProviderLoginChallenge? = null,
    /** The identity the provider confirmed. */
    val email: String = "",
    val error: String = "",
    /** Machines still to sign in after this one ("Sign in on all machines"). */
    val remaining: List<String> = emptyList(),
) {
    val finished: Boolean
        get() = phase in SignInPhases.FINISHED
}

object SignInPhases {
    const val STARTING = "starting"
    const val WAITING = "waiting"
    const val COMPLETING = "completing"
    const val SUCCEEDED = "succeeded"
    const val FAILED = "failed"
    const val CANCELED = "canceled"

    val FINISHED = setOf(SUCCEEDED, FAILED, CANCELED)

    fun of(phase: ProviderLoginPhase): String =
        when (phase) {
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_STARTING -> STARTING
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_WAITING -> WAITING
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_COMPLETING -> COMPLETING
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_SUCCEEDED -> SUCCEEDED
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_FAILED -> FAILED
            ProviderLoginPhase.PROVIDER_LOGIN_PHASE_CANCELED -> CANCELED
            else -> ""
        }

    /** code, none or callback: what a sign-in sheet asks for. */
    fun expects(input: ProviderLoginInput?): String =
        when (input) {
            ProviderLoginInput.PROVIDER_LOGIN_INPUT_CODE -> "code"
            ProviderLoginInput.PROVIDER_LOGIN_INPUT_NONE -> "none"
            ProviderLoginInput.PROVIDER_LOGIN_INPUT_CALLBACK -> "callback"
            else -> ""
        }

    fun flow(flow: String): ProviderLoginFlow =
        when (flow) {
            "" -> ProviderLoginFlow.PROVIDER_LOGIN_FLOW_UNSPECIFIED
            "paste_code" -> ProviderLoginFlow.PROVIDER_LOGIN_FLOW_PASTE_CODE
            "device_code" -> ProviderLoginFlow.PROVIDER_LOGIN_FLOW_DEVICE_CODE
            "browser" -> ProviderLoginFlow.PROVIDER_LOGIN_FLOW_BROWSER
            else -> throw CoreException(FailureKind.PERMANENT, "Unknown sign-in flow \"$flow\".")
        }
}

/**
 * This device's provider sign-ins. Each runs on the machine that signs in: Start, then a Watch
 * stream whose frames (a refreshed device code included) update the session, with Submit for a
 * pasted code or callback address and Cancel. "Sign in on all machines" walks every online machine
 * without a sign-in, one after another, in one session. A finished session keeps its final state
 * until it is dismissed; dismissing a live one cancels it. Confined to the core dispatcher.
 */
class ProviderSignIn(
    private val accounts: ProviderAccounts,
    private val machines: ProviderMachines,
    private val scope: CoroutineScope,
    private val logger: CoreLogger,
    private val newId: () -> String = { "signin_" + Uuid.random().toHexString() },
) {
    private val jobs = HashMap<String, Job>()

    /** Signs [accountId] in on [daemonId]; returns the session (an open one for both, if any). */
    fun start(accountId: String, daemonId: String, flow: String = ""): String {
        val view = accounts.view.value
        val account = signable(view, accountId)
        SignInPhases.flow(flow)
        if (view.machine(daemonId)?.reachable != true)
            throw CoreException(
                FailureKind.TRANSIENT,
                "${view.machineName(daemonId)} is offline; sign in when it is back.",
            )
        view.sessions
            .firstOrNull { it.accountId == account.id && it.daemonId == daemonId && !it.finished }
            ?.let {
                return it.id
            }
        return launch(SignInSession(newId(), account.id, daemonId, flow))
    }

    /** Signs [accountId] in on every online machine without a sign-in, this device's first. */
    fun startAll(accountId: String): String {
        val view = accounts.view.value
        val account = signable(view, accountId)
        val targets = view.reachable.filterNot { account.signedIn(it.id) }.map { it.id }
        if (targets.isEmpty())
            throw CoreException(
                FailureKind.PERMANENT,
                "${account.label} is signed in on every online machine.",
            )
        return launch(
            SignInSession(newId(), account.id, targets.first(), remaining = targets.drop(1))
        )
    }

    /** Hands a pasted [code] or the browser's [callbackUrl] to session [sessionId]. */
    suspend fun submit(sessionId: String, code: String?, callbackUrl: String?) {
        val session =
            session(sessionId)
                ?: throw CoreException(FailureKind.PERMANENT, "This sign-in is no longer open.")
        if (session.finished)
            throw CoreException(FailureKind.PERMANENT, "This sign-in has already finished.")
        if (session.loginId.isEmpty())
            throw CoreException(FailureKind.TRANSIENT, "The sign-in is still starting.")
        val pasted = code?.trim().orEmpty()
        val address = callbackUrl?.trim().orEmpty()
        val request =
            when {
                pasted.isNotEmpty() ->
                    SubmitProviderLoginInputRequest(login_id = session.loginId, code = pasted)
                address.isNotEmpty() ->
                    SubmitProviderLoginInputRequest(
                        login_id = session.loginId,
                        callback_url = address,
                    )
                else ->
                    throw CoreException(FailureKind.PERMANENT, "Paste the code or address first.")
            }
        val login =
            machines.call(session.daemonId) { api ->
                withDeadline(Deadlines.CALL) { api.SubmitProviderLoginInput().execute(request) }
            }
        apply(sessionId, login)
    }

    /** Cancels a live session on this device and on its machine. */
    suspend fun cancel(sessionId: String) {
        val session = session(sessionId) ?: return
        if (session.finished) return
        jobs.remove(sessionId)?.cancel()
        update(sessionId) {
            it.copy(phase = SignInPhases.CANCELED, remaining = emptyList(), error = "")
        }
        cancelOnMachine(session)
    }

    /** Drops a session from the list; a live one is canceled first, its machine told later. */
    fun dismiss(sessionId: String) {
        val session = session(sessionId) ?: return
        jobs.remove(sessionId)?.cancel()
        accounts.update { view ->
            view.copy(sessions = view.sessions.filterNot { it.id == sessionId })
        }
        if (!session.finished) scope.launch { cancelOnMachine(session) }
    }

    /** The account changed: every session belongs to the previous one. */
    fun reset() {
        jobs.values.forEach { it.cancel() }
        jobs.clear()
    }

    private fun signable(view: ProvidersView, accountId: String): ProviderAccountView {
        val account =
            view.account(accountId)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "This account is no longer available.",
                )
        if (!ProviderKinds.signsIn(account.method))
            throw CoreException(
                FailureKind.PERMANENT,
                "${account.label} follows each machine's own login; there is nothing to sign in.",
            )
        return account
    }

    private fun launch(session: SignInSession): String {
        accounts.update { it.copy(sessions = it.sessions + session) }
        val job =
            scope.launch(start = CoroutineStart.LAZY) {
                try {
                    drive(session.id)
                } finally {
                    if (jobs[session.id] === coroutineContext[Job]) jobs.remove(session.id)
                }
            }
        jobs[session.id] = job
        job.start()
        return session.id
    }

    /** Signs in on the session's machine, then on each remaining one while they succeed. */
    private suspend fun drive(id: String) {
        while (true) {
            signInOn(session(id) ?: return)
            val after = session(id) ?: return
            if (after.phase != SignInPhases.SUCCEEDED || after.remaining.isEmpty()) return
            update(id) {
                it.copy(
                    daemonId = it.remaining.first(),
                    remaining = it.remaining.drop(1),
                    loginId = "",
                    phase = SignInPhases.STARTING,
                    challenge = null,
                    email = "",
                    error = "",
                )
            }
        }
    }

    private suspend fun signInOn(session: SignInSession) {
        try {
            val login =
                machines.call(session.daemonId) { api ->
                    withDeadline(START_DEADLINE) {
                        api.StartProviderLogin()
                            .execute(
                                StartProviderLoginRequest(
                                    account_id = session.accountId,
                                    flow = SignInPhases.flow(session.flow),
                                )
                            )
                    }
                }
            apply(session.id, login)
            if (finished(session.id)) return
            watch(session.id, session.daemonId, login.login_id)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            fail(session.id, error)
        }
    }

    /**
     * Follows the login until it finishes. A stream that ends or breaks is opened again (the daemon
     * answers with the current state first), a bounded number of times in a row.
     */
    private suspend fun watch(id: String, daemonId: String, loginId: String) {
        var attempt = 0
        while (!finished(id)) {
            try {
                machines.call(daemonId) { api ->
                    coroutineScope {
                        val call = api.WatchProviderLogin()
                        val frames =
                            call.executeIn(
                                this,
                                WatchProviderLoginRequest(
                                    login_id = loginId,
                                    heartbeat_seconds = HEARTBEAT_SECONDS,
                                ),
                            )
                        try {
                            for (frame in frames) {
                                attempt = 0
                                apply(id, frame)
                                if (finished(id)) break
                            }
                        } finally {
                            call.cancel()
                            coroutineContext.cancelChildren()
                        }
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                if (Failures.kind(error) == FailureKind.PERMANENT) {
                    fail(id, error)
                    return
                }
                logger.debug(TAG, "sign-in watch ended: ${Failures.message(error)}")
            }
            if (finished(id)) return
            if (attempt >= MAX_WATCH_ATTEMPTS) {
                update(id) {
                    if (it.finished) it
                    else
                        it.copy(
                            phase = SignInPhases.FAILED,
                            error = "The machine stopped reporting this sign-in.",
                        )
                }
                return
            }
            delay(WATCH_BACKOFF.delay(attempt++))
        }
    }

    private fun apply(id: String, login: ProviderLogin) =
        update(id) { session ->
            // Only the session's own login moves it, and never past a final state.
            if (
                session.finished ||
                    (session.loginId.isNotEmpty() &&
                        login.login_id.isNotEmpty() &&
                        login.login_id != session.loginId)
            )
                return@update session
            val phase = SignInPhases.of(login.phase).ifEmpty { session.phase }
            session.copy(
                loginId = login.login_id.ifEmpty { session.loginId },
                phase = phase,
                challenge = login.challenge ?: session.challenge,
                email = login.identity?.email?.ifEmpty { null } ?: session.email,
                error =
                    if (phase == SignInPhases.FAILED)
                        login.error_message
                            .ifEmpty { login.error_code }
                            .ifEmpty { "Sign-in failed." }
                    else "",
            )
        }

    private fun fail(id: String, error: Throwable) =
        update(id) {
            if (it.finished) it
            else it.copy(phase = SignInPhases.FAILED, error = providerProblem(error))
        }

    private suspend fun cancelOnMachine(session: SignInSession) {
        if (session.loginId.isEmpty()) return
        try {
            machines.call(session.daemonId) { api ->
                withDeadline(Deadlines.CALL) {
                    api.CancelProviderLogin()
                        .execute(CancelProviderLoginRequest(login_id = session.loginId))
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            logger.info(TAG, "could not cancel a sign-in: ${Failures.message(error)}")
        }
    }

    private fun session(id: String): SignInSession? = accounts.view.value.session(id)

    private fun finished(id: String): Boolean = session(id)?.finished ?: true

    private fun update(id: String, transform: (SignInSession) -> SignInSession) {
        accounts.update { view ->
            view.copy(sessions = view.sessions.map { if (it.id == id) transform(it) else it })
        }
    }

    companion object {
        const val HEARTBEAT_SECONDS = 15
        const val MAX_WATCH_ATTEMPTS = 5

        /** Starting runs the provider's CLI until it shows its sign-in address. */
        private val START_DEADLINE = 60.seconds
        private val WATCH_BACKOFF = Backoff(500.milliseconds, 5.seconds)
        private const val TAG = "ProviderSignIn"
    }
}
