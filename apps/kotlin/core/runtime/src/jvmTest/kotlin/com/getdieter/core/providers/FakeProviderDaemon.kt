package com.getdieter.core.providers

import com.getdieter.api.v1.CancelProviderLoginRequest
import com.getdieter.api.v1.CheckProviderLoginRequest
import com.getdieter.api.v1.ConsumeProviderUsageResetRequest
import com.getdieter.api.v1.ConsumeProviderUsageResetResponse
import com.getdieter.api.v1.CreateProviderAccountRequest
import com.getdieter.api.v1.DeleteProviderAccountRequest
import com.getdieter.api.v1.GetProviderTurnTokenRequest
import com.getdieter.api.v1.ListProviderAccountsRequest
import com.getdieter.api.v1.ListProviderAccountsResponse
import com.getdieter.api.v1.ProviderAccount
import com.getdieter.api.v1.ProviderAccountServiceClient
import com.getdieter.api.v1.ProviderLogin
import com.getdieter.api.v1.ProviderLoginChallenge
import com.getdieter.api.v1.ProviderLoginInput
import com.getdieter.api.v1.ProviderLoginPhase
import com.getdieter.api.v1.ProviderTurnToken
import com.getdieter.api.v1.RefreshProviderUsageRequest
import com.getdieter.api.v1.SetDefaultProviderAccountRequest
import com.getdieter.api.v1.SignOutProviderAccountRequest
import com.getdieter.api.v1.StartProviderLoginRequest
import com.getdieter.api.v1.SubmitProviderLoginInputRequest
import com.getdieter.api.v1.UpdateProviderAccountRequest
import com.getdieter.api.v1.WatchProviderLoginRequest
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcServerStreamingCall
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.produce

/**
 * One machine's ProviderAccountService for tests: it records every request, answers sign-ins with a
 * waiting login, and streams whatever frames the test sends to its latest watch.
 */
class FakeProviderDaemon(val id: String) : ProviderAccountServiceClient {
    val starts = mutableListOf<StartProviderLoginRequest>()
    val watches = mutableListOf<WatchProviderLoginRequest>()
    val submits = mutableListOf<SubmitProviderLoginInputRequest>()
    val cancels = mutableListOf<String>()
    val creates = mutableListOf<CreateProviderAccountRequest>()
    val updates = mutableListOf<UpdateProviderAccountRequest>()
    val deletes = mutableListOf<String>()
    val signOuts = mutableListOf<String>()
    val refreshes = mutableListOf<String>()
    val resets = mutableListOf<ConsumeProviderUsageResetRequest>()

    /** One channel per opened watch; the test sends frames to the latest. */
    val streams = mutableListOf<Channel<ProviderLogin>>()

    /** Every unary request in order, answered or not. */
    val attempts = mutableListOf<Any>()

    /** Every call but a watch runs this first, e.g. to fail or to wait on a gate. */
    var before: suspend (method: String) -> Unit = {}

    var challenge =
        ProviderLoginChallenge(
            open_url = "https://example.test/oauth",
            expects = ProviderLoginInput.PROVIDER_LOGIN_INPUT_CODE,
        )
    var resetOutcome = "reset"

    fun login(
        phase: ProviderLoginPhase,
        accountId: String = "",
        vararg changes: (ProviderLogin) -> ProviderLogin,
    ): ProviderLogin =
        changes.fold(
            ProviderLogin(
                login_id = "login-$id",
                account_id = accountId,
                daemon_id = id,
                phase = phase,
                challenge = challenge,
            )
        ) { login, change ->
            change(login)
        }

    /** Sends [frame] to the latest watch. */
    suspend fun emit(frame: ProviderLogin) = streams.last().send(frame)

    override fun StartProviderLogin(): GrpcCall<StartProviderLoginRequest, ProviderLogin> =
        unary("StartProviderLogin") {
            starts += it
            login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_WAITING, it.account_id)
        }

    override fun WatchProviderLogin():
        GrpcServerStreamingCall<WatchProviderLoginRequest, ProviderLogin> =
        object :
            GrpcServerStreamingCall<
                WatchProviderLoginRequest,
                ProviderLogin,
            > by GrpcServerStreamingCall({ _ -> }) {
            private var produced: ReceiveChannel<ProviderLogin>? = null

            override suspend fun executeIn(
                scope: CoroutineScope,
                request: WatchProviderLoginRequest,
            ): ReceiveChannel<ProviderLogin> {
                watches += request
                val frames = Channel<ProviderLogin>(Channel.UNLIMITED).also { streams += it }
                return scope.produce { for (frame in frames) send(frame) }.also { produced = it }
            }

            override fun cancel() {
                produced?.cancel()
            }
        }

    override fun SubmitProviderLoginInput():
        GrpcCall<SubmitProviderLoginInputRequest, ProviderLogin> =
        unary("SubmitProviderLoginInput") {
            submits += it
            login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_COMPLETING)
        }

    override fun CancelProviderLogin(): GrpcCall<CancelProviderLoginRequest, ProviderLogin> =
        unary("CancelProviderLogin") {
            cancels += it.login_id
            login(ProviderLoginPhase.PROVIDER_LOGIN_PHASE_CANCELED)
        }

    override fun CreateProviderAccount(): GrpcCall<CreateProviderAccountRequest, ProviderAccount> =
        unary("CreateProviderAccount") {
            creates += it
            ProviderAccount(
                id = it.account_id,
                provider = it.provider,
                label = it.label,
                method = it.method,
                include_in_summary = true,
                created_by = id,
            )
        }

    override fun UpdateProviderAccount(): GrpcCall<UpdateProviderAccountRequest, ProviderAccount> =
        unary("UpdateProviderAccount") {
            updates += it
            ProviderAccount(id = it.account_id)
        }

    override fun DeleteProviderAccount(): GrpcCall<DeleteProviderAccountRequest, Unit> =
        unary("DeleteProviderAccount") { deletes += it.account_id }

    override fun SetDefaultProviderAccount():
        GrpcCall<SetDefaultProviderAccountRequest, ProviderAccount> =
        unary("SetDefaultProviderAccount") { ProviderAccount(id = it.account_id) }

    override fun SignOutProviderAccount():
        GrpcCall<SignOutProviderAccountRequest, ProviderAccount> =
        unary("SignOutProviderAccount") {
            signOuts += it.account_id
            ProviderAccount(id = it.account_id)
        }

    override fun CheckProviderLogin(): GrpcCall<CheckProviderLoginRequest, ProviderAccount> =
        unary("CheckProviderLogin") { ProviderAccount(id = it.account_id) }

    override fun RefreshProviderUsage(): GrpcCall<RefreshProviderUsageRequest, ProviderAccount> =
        unary("RefreshProviderUsage") {
            refreshes += it.account_id
            ProviderAccount(id = it.account_id)
        }

    override fun ConsumeProviderUsageReset():
        GrpcCall<ConsumeProviderUsageResetRequest, ConsumeProviderUsageResetResponse> =
        unary("ConsumeProviderUsageReset") {
            resets += it
            ConsumeProviderUsageResetResponse(outcome = resetOutcome)
        }

    override fun ListProviderAccounts():
        GrpcCall<ListProviderAccountsRequest, ListProviderAccountsResponse> = error("unused")

    override fun GetProviderTurnToken(): GrpcCall<GetProviderTurnTokenRequest, ProviderTurnToken> =
        error("unused")

    private fun <S : Any, R : Any> unary(method: String, answer: (S) -> R): GrpcCall<S, R> =
        object : GrpcCall<S, R> by GrpcCall(answer) {
            override suspend fun execute(request: S): R {
                attempts += request
                before(method)
                return answer(request)
            }
        }
}

/** [ProviderMachines] over fake daemons, by machine ID. */
class FakeProviderFleet(vararg daemons: FakeProviderDaemon) : ProviderMachines {
    val byId = daemons.associateBy { it.id }

    override suspend fun <T> call(
        machineId: String,
        block: suspend (ProviderAccountServiceClient) -> T,
    ): T = block(byId.getValue(machineId))
}
