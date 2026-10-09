package com.dbpprt.dieter.core.design

import com.dbpprt.dieter.api.v1.ClaudeDesignSignInEvent
import com.dbpprt.dieter.api.v1.ClaudeDesignStatus
import com.dbpprt.dieter.api.v1.SetClaudeDesignAccessRequest
import com.dbpprt.dieter.api.v1.SignInClaudeDesignRequest
import com.dbpprt.dieter.api.v1.SubmitClaudeDesignSignInCodeRequest
import com.dbpprt.dieter.core.routing.RouteKind
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Where a machine's Claude Design sign-in stands. */
enum class ClaudeDesignSignInPhase {
    STARTING,
    PREPARING,
    WAITING,
    CHECKING_CODE,
    SUCCEEDED,
    FAILED,
}

data class ClaudeDesignSignIn(
    val id: String = "",
    val phase: ClaudeDesignSignInPhase = ClaudeDesignSignInPhase.STARTING,
    /** Finishes by itself in a browser on the machine. */
    val url: String = "",
    /** Shows a code to paste into Dieter; works from any device. */
    val manualUrl: String = "",
    val manualFirst: Boolean = false,
    val message: String = "",
    /**
     * The progress stream dropped, e.g. while a phone was in the browser. The machine keeps the
     * sign-in open, so its code still completes it.
     */
    val detached: Boolean = false,
) {
    val active: Boolean
        get() =
            phase != ClaudeDesignSignInPhase.SUCCEEDED && phase != ClaudeDesignSignInPhase.FAILED
}

data class ClaudeDesignView(
    val daemonId: String? = null,
    /** Null until read. */
    val status: ClaudeDesignStatus? = null,
    val loading: Boolean = false,
    /** Why the status could not be read or an access change failed. */
    val error: String? = null,
    /** Null when no sign-in ran since the machine was shown. */
    val signIn: ClaudeDesignSignIn? = null,
    val accessPending: Boolean = false,
    /** The machine is this device, so its browser sign-in page can finish here. */
    val local: Boolean = false,
)

/** What every client shows for [ClaudeDesignView]. */
data class ClaudeDesignPresentation(
    val headline: String,
    val detail: String,
    val accessDetail: String,
    val canSignIn: Boolean,
    val canChangeAccess: Boolean,
    /** The page to open for the running sign-in; empty until it is ready. */
    val openUrl: String,
    /** The page shows a code to paste into Dieter. */
    val codeRequired: Boolean,
) {
    companion object {
        fun of(view: ClaudeDesignView): ClaudeDesignPresentation {
            val status = view.status
            val signIn = view.signIn
            val (headline, detail) =
                when {
                    view.daemonId == null ->
                        "No machine" to "Choose a machine to connect Claude Design."
                    status == null && view.loading ->
                        "Checking…" to "Reading Claude Design on this machine."
                    status == null ->
                        "Status unavailable" to
                            (view.error ?: "Claude Design status could not be read.")
                    !status.runtime_ready && status.can_sign_in ->
                        "Not signed in" to
                            status.reason.ifEmpty {
                                "Signing in installs Claude Code ${status.claude_code_version} on this machine."
                            }
                    !status.available ->
                        "Unavailable" to
                            status.reason.ifEmpty {
                                "Claude Design isn't available for the Claude account on this machine. It needs a paid Claude plan with Claude Design enabled."
                            }
                    status.signed_in ->
                        "Signed in" to
                            "Claude Code on this machine can reach Claude Design with this machine's Claude account."
                    else ->
                        "Not signed in" to
                            "Sign in with the Claude account on this machine. Claude Code keeps the credential there; Dieter never copies it."
                }
            val code = signIn != null && (!view.local || signIn.manualFirst || signIn.url.isEmpty())
            val manualUrl = signIn?.manualUrl.orEmpty()
            return ClaudeDesignPresentation(
                headline = headline,
                detail = detail,
                accessDetail =
                    "Claude Code turns on this machine can create and edit Claude Design projects. " +
                        "Turning this on grants your Claude account's agent access to Design projects.",
                canSignIn = status?.can_sign_in == true && signIn?.active != true,
                canChangeAccess =
                    status != null &&
                        (status.available || status.access_enabled) &&
                        !view.accessPending,
                openUrl = signIn?.let { if (code) it.manualUrl else it.url }.orEmpty(),
                codeRequired = code && manualUrl.isNotEmpty(),
            )
        }
    }
}

/**
 * The shown machine's Claude Design: its status, a sign-in that runs while the surface is observed,
 * and whether its Claude Code turns may use Claude Design. Confined to the core dispatcher.
 */
class ClaudeDesign(private val sessions: MachineSessions, private val scope: CoroutineScope) {
    private val mutableView = MutableStateFlow(ClaudeDesignView())
    val view: StateFlow<ClaudeDesignView> = mutableView.asStateFlow()
    private var generation = 0L
    private var reader: Job? = null
    private var signInJob: Job? = null
    private var outcomeJob: Job? = null

    /** Shows [daemonId] and reads it; another machine cancels a running sign-in. */
    fun select(daemonId: String?) {
        if (daemonId == view.value.daemonId) {
            if (daemonId != null && !view.value.loading) refreshLater()
            return
        }
        generation++
        reader?.cancel()
        signInJob?.cancel()
        signInJob = null
        outcomeJob?.cancel()
        mutableView.value = ClaudeDesignView(daemonId = daemonId)
        if (daemonId != null) refreshLater()
    }

    /** The view went away: a running sign-in ends with it. */
    fun stop() = select(null)

    /** Account or gateway changed. */
    fun reset() = select(null)

    private fun refreshLater() {
        reader?.cancel()
        reader = scope.launch { refresh() }
    }

    suspend fun refresh() {
        val daemonId = view.value.daemonId ?: return
        val bound = generation
        change(bound) { it.copy(loading = true) }
        try {
            val status =
                sessions.call(daemonId, STATUS_DEADLINE) {
                    it.GetClaudeDesignStatus().execute(Unit)
                }
            change(bound) {
                it.copy(status = status, loading = false, error = null, local = local(daemonId))
            }
        } catch (cancelled: CancellationException) {
            change(bound) { it.copy(loading = false) }
            throw cancelled
        } catch (error: Throwable) {
            change(bound) { it.copy(loading = false, error = message(error)) }
        }
    }

    /** Starts a sign-in on the shown machine; one runs at a time. */
    fun signIn() {
        val daemonId = view.value.daemonId ?: return
        if (signInJob?.isActive == true) return
        val bound = generation
        change(bound) { it.copy(signIn = ClaudeDesignSignIn(), error = null) }
        signInJob = scope.launch {
            try {
                coroutineScope {
                    sessions.call(daemonId) { client ->
                        val call = client.SignInClaudeDesign()
                        val events = call.executeIn(this, SignInClaudeDesignRequest())
                        try {
                            for (event in events) {
                                accept(bound, daemonId, event)
                                if (event.done) break
                            }
                        } finally {
                            call.cancel()
                        }
                    }
                }
                streamEnded(bound, daemonId, "The sign-in ended before it finished. Try again.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                streamEnded(bound, daemonId, message(error))
            }
        }
    }

    /**
     * The progress stream ended before the sign-in did. A sign-in that already showed its page
     * stays usable: the machine keeps it open for its code.
     */
    private fun streamEnded(bound: Long, daemonId: String, message: String) {
        val signIn = view.value.signIn
        val waiting =
            signIn != null &&
                signIn.id.isNotEmpty() &&
                (signIn.phase == ClaudeDesignSignInPhase.WAITING ||
                    signIn.phase == ClaudeDesignSignInPhase.CHECKING_CODE)
        if (bound != generation || !waiting) {
            fail(bound, message)
            return
        }
        change(bound) { it.copy(signIn = it.signIn?.copy(detached = true)) }
        if (signIn?.phase == ClaudeDesignSignInPhase.CHECKING_CODE) awaitOutcome(bound, daemonId)
    }

    /** Without a stream, the machine's status tells when a submitted code finished the sign-in. */
    private fun awaitOutcome(bound: Long, daemonId: String) {
        outcomeJob?.cancel()
        outcomeJob = scope.launch {
            repeat(OUTCOME_POLLS) {
                delay(OUTCOME_INTERVAL)
                if (
                    bound != generation ||
                        view.value.signIn?.phase != ClaudeDesignSignInPhase.CHECKING_CODE
                )
                    return@launch
                val status =
                    try {
                        sessions.call(daemonId, STATUS_DEADLINE) {
                            it.GetClaudeDesignStatus().execute(Unit)
                        }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        null
                    }
                if (status != null && !status.sign_in_active) {
                    change(bound) { state ->
                        state.copy(
                            status = status,
                            signIn =
                                state.signIn?.copy(
                                    phase =
                                        if (status.signed_in) ClaudeDesignSignInPhase.SUCCEEDED
                                        else ClaudeDesignSignInPhase.FAILED,
                                    message =
                                        if (status.signed_in) "Signed in to Claude Design."
                                        else "The code did not finish the sign-in. Start it again.",
                                ),
                        )
                    }
                    return@launch
                }
            }
            fail(bound, "The sign-in did not finish. Start it again.")
        }
    }

    fun cancelSignIn() {
        signInJob?.cancel()
        signInJob = null
        outcomeJob?.cancel()
        change(generation) { it.copy(signIn = null) }
        refreshLater()
    }

    /** Sends the code the manual sign-in page shows; the sign-in reports the outcome. */
    suspend fun submitCode(code: String) {
        val state = view.value
        val daemonId = state.daemonId ?: return
        val signIn = state.signIn ?: return
        val value = code.trim()
        if (
            value.isEmpty() ||
                signIn.id.isEmpty() ||
                signIn.phase != ClaudeDesignSignInPhase.WAITING
        )
            return
        val bound = generation
        change(bound) {
            it.copy(
                signIn =
                    it.signIn?.copy(phase = ClaudeDesignSignInPhase.CHECKING_CODE, message = "")
            )
        }
        try {
            sessions.call(daemonId, Deadlines.CALL) {
                it.SubmitClaudeDesignSignInCode()
                    .execute(
                        SubmitClaudeDesignSignInCodeRequest(sign_in_id = signIn.id, code = value)
                    )
            }
            // A live stream reports the outcome; otherwise ask the machine.
            if (view.value.signIn?.detached == true) awaitOutcome(bound, daemonId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            change(bound) { state ->
                state.copy(
                    signIn =
                        state.signIn
                            ?.takeIf { it.active }
                            ?.copy(
                                phase = ClaudeDesignSignInPhase.WAITING,
                                message = message(error),
                            ) ?: state.signIn
                )
            }
        }
    }

    /**
     * Allows or stops Claude Design in the machine's Claude Code turns. Allowing also grants the
     * Claude account's agent access; [revokeGrant] withdraws it for every Claude Code session.
     */
    suspend fun setAccess(enabled: Boolean, revokeGrant: Boolean = false) {
        val state = view.value
        val daemonId = state.daemonId ?: return
        if (state.accessPending) return
        val bound = generation
        change(bound) { it.copy(accessPending = true, error = null) }
        try {
            val status =
                sessions.call(daemonId, ACCESS_DEADLINE) {
                    it.SetClaudeDesignAccess()
                        .execute(
                            SetClaudeDesignAccessRequest(
                                enabled = enabled,
                                revoke_grant = revokeGrant && !enabled,
                            )
                        )
                }
            change(bound) { it.copy(status = status, accessPending = false) }
        } catch (cancelled: CancellationException) {
            change(bound) { it.copy(accessPending = false) }
            throw cancelled
        } catch (error: Throwable) {
            change(bound) { it.copy(accessPending = false, error = message(error)) }
            refreshLater()
        }
    }

    private fun accept(bound: Long, daemonId: String, event: ClaudeDesignSignInEvent) =
        change(bound) { state ->
            val current =
                (state.signIn ?: ClaudeDesignSignIn()).let {
                    if (event.sign_in_id.isEmpty()) it else it.copy(id = event.sign_in_id)
                }
            when {
                event.done ->
                    state.copy(
                        status = event.status ?: state.status,
                        local = local(daemonId),
                        signIn =
                            current.copy(
                                phase =
                                    if (event.ok) ClaudeDesignSignInPhase.SUCCEEDED
                                    else ClaudeDesignSignInPhase.FAILED,
                                message =
                                    event.message.ifEmpty {
                                        if (event.ok) "Signed in to Claude Design."
                                        else "The sign-in did not finish."
                                    },
                            ),
                    )
                event.preparing ->
                    state.copy(
                        signIn =
                            current.copy(
                                phase = ClaudeDesignSignInPhase.PREPARING,
                                message = event.message,
                            )
                    )
                event.url.isNotEmpty() || event.manual_url.isNotEmpty() ->
                    state.copy(
                        local = local(daemonId),
                        signIn =
                            current.copy(
                                phase = ClaudeDesignSignInPhase.WAITING,
                                url = event.url,
                                manualUrl = event.manual_url,
                                manualFirst = event.manual_first,
                                message = "",
                            ),
                    )
                else -> state.copy(signIn = current)
            }
        }

    private fun fail(bound: Long, message: String) =
        change(bound) { state ->
            val signIn = state.signIn?.takeIf { it.active } ?: return@change state
            state.copy(
                signIn = signIn.copy(phase = ClaudeDesignSignInPhase.FAILED, message = message)
            )
        }

    private fun local(daemonId: String): Boolean =
        sessions.routes.value[daemonId]?.kind == RouteKind.LOCAL

    private fun change(bound: Long, update: (ClaudeDesignView) -> ClaudeDesignView) {
        if (bound != generation) return
        mutableView.update(update)
    }

    companion object {
        /** Reading the status runs Claude Code on the machine. */
        val STATUS_DEADLINE = 1.minutes

        /** Granting or revoking access runs Claude Code on the machine. */
        val ACCESS_DEADLINE = 3.minutes

        /** How often, and how long, a detached sign-in's code is followed: two minutes. */
        private val OUTCOME_INTERVAL = 2.seconds
        private const val OUTCOME_POLLS = 60

        /** A daemon message for a refused change; older releases lack Claude Design. */
        fun message(error: Throwable): String =
            if (error is GrpcException) {
                when (error.grpcStatus) {
                    GrpcStatus.UNIMPLEMENTED ->
                        "Update Dieter on this machine to use Claude Design."
                    GrpcStatus.FAILED_PRECONDITION,
                    GrpcStatus.INVALID_ARGUMENT,
                    GrpcStatus.NOT_FOUND ->
                        Failures.scrub(error.grpcMessage.orEmpty()).ifEmpty {
                            Failures.message(error)
                        }
                    else -> Failures.message(error)
                }
            } else {
                Failures.message(error)
            }
    }
}
