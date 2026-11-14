package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The gateway turned down this device's session (it expired, was revoked, or there is none), so the
 * connection waits for a new sign-in instead of retrying.
 */
val SessionSlice.needsSignIn: Boolean
    get() = phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED

/** The account session: connection, sign-in, and replays a person asks for. */
class SessionModel
internal constructor(private val context: StoreContext, private val changed: () -> Unit = {}) {
    val slice = MutableStateFlow(SessionSlice())
    val signInUrl = MutableStateFlow("")
    val refreshing = MutableStateFlow(false)
    private var refreshCompletion: CompletableDeferred<Unit>? = null
    private var refreshSawReplay = false

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_SESSION, "") { update ->
            update.session?.let {
                slice.value = it
                changed()
                if (refreshCompletion != null) {
                    if (!it.synced) refreshSawReplay = true
                    if (refreshSawReplay && (it.synced || it.notice?.offline == true))
                        refreshCompletion?.complete(Unit)
                }
            }
        }
    }

    fun signIn(url: String) = context.action {
        signInUrl.value =
            context.core
                .dispatch(Command(begin_sign_in = BeginSignIn(url)))
                .sign_in_started
                ?.authorize_url
                .orEmpty()
    }

    /**
     * Signs in to the active gateway again, e.g. after its session expired. The cached workspace,
     * undelivered changes and this device's trust stay; only the session is replaced.
     */
    fun signInAgain() = signIn(slice.value.gateway_origin)

    fun completeSignIn(url: String) = context.action {
        context.core.dispatch(Command(complete_sign_in = CompleteSignIn(url)))
    }

    fun retry() = context.action { context.core.dispatch(Command(reconnect = Reconnect())) }

    /**
     * What a Reconnect button does: retries the connection, or signs in again when the gateway no
     * longer accepts this device's session, where retrying only fails the same way.
     */
    fun reconnect() = if (slice.value.needsSignIn) signInAgain() else retry()

    /** Replays the account while keeping the visible lists, filters and drafts. */
    fun refresh() {
        if (context.closed || refreshing.value) return
        refreshing.value = true
        context.scope.launch {
            try {
                val completion = CompletableDeferred<Unit>()
                context.serialized {
                    context.error.value = ""
                    refreshSawReplay = !slice.value.synced
                    refreshCompletion = completion
                    context.core.dispatch(Command(resync = Resync()))
                }
                // The command admits a replay; the session confirms when it has caught up.
                // Bound the gesture's indicator while the core continues its own recovery.
                if (withTimeoutOrNull(30_000) { completion.await() } == null)
                    context.error.value = "Sync is still catching up. Dieter will keep trying."
                if (slice.value.synced)
                    context.serialized {
                        context.core.dispatch(
                            Command(
                                chats =
                                    ChatsCommand(scope = MobileStore.CHATS_SCOPE, reload = Step())
                            )
                        )
                    }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                context.error.value = failure.message ?: "Could not refresh."
            } finally {
                refreshCompletion = null
                refreshing.value = false
            }
        }
    }
}
