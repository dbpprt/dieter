package com.getdieter.core.providers

import com.getdieter.api.v1.CheckProviderLoginRequest
import com.getdieter.api.v1.ConsumeProviderUsageResetRequest
import com.getdieter.api.v1.CreateProviderAccountRequest
import com.getdieter.api.v1.DeleteProviderAccountRequest
import com.getdieter.api.v1.ProviderAccountServiceClient
import com.getdieter.api.v1.ProviderKind
import com.getdieter.api.v1.ProviderLoginMethod
import com.getdieter.api.v1.RefreshProviderUsageRequest
import com.getdieter.api.v1.SetDefaultProviderAccountRequest
import com.getdieter.api.v1.SignOutProviderAccountRequest
import com.getdieter.api.v1.UpdateProviderAccountRequest
import com.getdieter.client.v1.Done
import com.getdieter.client.v1.ProviderAccountRef
import com.getdieter.client.v1.ProviderCreate
import com.getdieter.client.v1.ProviderResetOutcome
import com.getdieter.client.v1.ProviderSignInStarted
import com.getdieter.client.v1.ProvidersCommand
import com.getdieter.client.v1.Result
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.Deadlines
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.secureRandomBytes
import com.getdieter.core.runtime.withDeadline
import com.squareup.wire.GrpcException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.uuid.Uuid

/** Provider account IDs as the daemons key them: `pa_` and 26 base32 characters. */
object ProviderIds {
    private const val ALPHABET = "abcdefghijklmnopqrstuvwxyz234567"

    fun account(): String =
        "pa_" + secureRandomBytes(26).joinToString("") { ALPHABET[it.toInt() and 31].toString() }

    fun valid(id: String): Boolean =
        id.length == 29 && id.startsWith("pa_") && id.drop(3).all { it in ALPHABET }
}

/** A failure as one line for the providers slice: the daemon's own words when it gave any. */
internal fun providerProblem(error: Throwable): String =
    (error as? GrpcException)?.grpcMessage?.trim()?.takeIf { it.isNotEmpty() }
        ?: Failures.message(error)

/**
 * Executes [ProvidersCommand]s. Account-wide edits go to any reachable machine, this device's
 * first; machine actions go to the machine they name; usage and resets go to a reachable machine
 * where the account is signed in. Each account takes one change at a time
 * ([ProvidersView.mutating]). A retried create reuses its account ID and a retried reset its
 * idempotency key until a machine answered, so neither happens twice. A created account shows at
 * once ([ProviderAccounts.created]) and its account-wide edits go to the machine that created it
 * until the replica has its record. Confined to the core dispatcher.
 */
class ProviderCommands(
    private val accounts: ProviderAccounts,
    private val signIn: ProviderSignIn,
    private val machines: ProviderMachines,
    private val newAccountId: () -> String = ProviderIds::account,
    private val newResetKey: () -> String = { Uuid.random().toString() },
) {
    private val createIds = HashMap<String, String>()
    private val resetKeys = HashMap<String, String>()

    suspend fun execute(command: ProvidersCommand): Result {
        val done = Result(done = Done())
        command.create?.let {
            return Result(provider_account = ProviderAccountRef(create(it)))
        }
        command.rename?.let { rename ->
            val label = label(rename.label)
            accountWide(rename.account_id) { api ->
                api.UpdateProviderAccount()
                    .execute(
                        UpdateProviderAccountRequest(account_id = rename.account_id, label = label)
                    )
            }
            return done
        }
        command.remove?.let { ref ->
            accountWide(ref.account_id) { api ->
                api.DeleteProviderAccount()
                    .execute(DeleteProviderAccountRequest(account_id = ref.account_id))
            }
            accounts.forget(ref.account_id)
            return done
        }
        command.set_default?.let { ref ->
            accountWide(ref.account_id) { api ->
                api.SetDefaultProviderAccount()
                    .execute(SetDefaultProviderAccountRequest(account_id = ref.account_id))
            }
            return done
        }
        command.set_included?.let { inclusion ->
            accountWide(inclusion.account_id) { api ->
                api.UpdateProviderAccount()
                    .execute(
                        UpdateProviderAccountRequest(
                            account_id = inclusion.account_id,
                            include_in_summary = inclusion.included,
                        )
                    )
            }
            return done
        }
        command.set_omp_access?.let { access ->
            if (known(access.account_id).provider != ProviderKinds.CLAUDE)
                throw CoreException(
                    FailureKind.PERMANENT,
                    "Only Claude accounts need Oh My Pi access; ChatGPT logins work as they are.",
                )
            accountWide(access.account_id) { api ->
                api.UpdateProviderAccount()
                    .execute(
                        UpdateProviderAccountRequest(
                            account_id = access.account_id,
                            omp_access = access.allowed,
                        )
                    )
            }
            return done
        }
        command.sign_in?.let {
            val id = signIn.start(required(it.account_id), required(it.daemon_id), it.flow)
            return Result(provider_sign_in = ProviderSignInStarted(id))
        }
        command.sign_in_all?.let {
            return Result(
                provider_sign_in = ProviderSignInStarted(signIn.startAll(required(it.account_id)))
            )
        }
        command.submit?.let {
            signIn.submit(it.session_id, it.code, it.callback_url)
            return done
        }
        command.cancel?.let {
            signIn.cancel(it.session_id)
            return done
        }
        command.dismiss?.let {
            signIn.dismiss(it.session_id)
            return done
        }
        command.sign_out?.let { ref ->
            onMachine(ref.account_id, ref.daemon_id) { api ->
                api.SignOutProviderAccount()
                    .execute(SignOutProviderAccountRequest(account_id = ref.account_id))
            }
            return done
        }
        command.check?.let { ref ->
            onMachine(ref.account_id, ref.daemon_id) { api ->
                api.CheckProviderLogin()
                    .execute(CheckProviderLoginRequest(account_id = ref.account_id))
            }
            return done
        }
        command.refresh_usage?.let { ref ->
            val machine = signedInMachine(ref.account_id)
            onMachine(ref.account_id, machine) { api ->
                api.RefreshProviderUsage()
                    .execute(RefreshProviderUsageRequest(account_id = ref.account_id))
            }
            return done
        }
        command.consume_reset?.let {
            return Result(provider_reset = consumeReset(required(it.account_id)))
        }
        throw CoreException(FailureKind.PERMANENT, "Choose what to do with the provider accounts.")
    }

    /** The account or gateway changed: retries of earlier actions no longer apply. */
    fun reset() {
        createIds.clear()
        resetKeys.clear()
    }

    private suspend fun create(create: ProviderCreate): String {
        val provider = create.provider
        val kind =
            when (provider) {
                ProviderKinds.CLAUDE -> ProviderKind.PROVIDER_KIND_CLAUDE
                ProviderKinds.CHATGPT -> ProviderKind.PROVIDER_KIND_CHATGPT
                else -> throw CoreException(FailureKind.PERMANENT, "Choose Claude or ChatGPT.")
            }
        val method = create.method.ifEmpty { ProviderKinds.defaultMethod(provider) }
        if (method !in ProviderKinds.creatableMethods(provider))
            throw CoreException(
                FailureKind.PERMANENT,
                "${ProviderKinds.name(provider)} accounts cannot use ${ProviderKinds.methodLabel(method)}.",
            )
        val label = label(create.label)
        val retry = "$provider\n$method\n$label"
        val id = createIds.getOrPut(retry) { newAccountId() }
        val machine = anyMachine(id)
        val created =
            onMachine(id, machine) { api ->
                api.CreateProviderAccount()
                    .execute(
                        CreateProviderAccountRequest(
                            provider = kind,
                            label = label,
                            method = method(method),
                            account_id = id,
                        )
                    )
            }
        createIds.remove(retry)
        // Shown at once, so a sign-in can follow before the replica delivers the record.
        val record =
            AccountRecord(
                id = created.id.ifEmpty { id },
                provider = providerName(created.provider) ?: provider,
                label = created.label.ifEmpty { label },
                method = methodName(created.method) ?: method,
                identity =
                    created.identity?.let {
                        AccountIdentity(
                            email = it.email,
                            organization = it.organization,
                            organizationId = it.organization_id,
                            workspaceId = it.workspace_id,
                            subject = it.subject,
                            plan = it.plan,
                        )
                    } ?: AccountIdentity(),
                includeInSummary = created.include_in_summary,
                createdAt = created.created_at,
                createdBy = created.created_by,
                ompAccess = created.omp_access,
            )
        accounts.created(PendingAccount(record, created.is_default, machine))
        return record.id
    }

    /**
     * Spends one ChatGPT reset credit on a reachable machine signed in to the account. The key
     * stays until a machine answers, so retrying the same action never spends a second credit.
     */
    private suspend fun consumeReset(accountId: String): ProviderResetOutcome {
        val account = known(accountId)
        if (account.provider != ProviderKinds.CHATGPT)
            throw CoreException(FailureKind.PERMANENT, "Only ChatGPT accounts have reset credits.")
        val machine = signedInMachine(accountId)
        val key = resetKeys.getOrPut(accountId) { newResetKey() }
        val response =
            onMachine(accountId, machine) { api ->
                api.ConsumeProviderUsageReset()
                    .execute(
                        ConsumeProviderUsageResetRequest(
                            account_id = accountId,
                            idempotency_key = key,
                        )
                    )
            }
        resetKeys.remove(accountId)
        return ProviderResetOutcome(
            account_id = accountId,
            outcome = response.outcome,
            message = ProviderUsages.resetMessage(response.outcome),
        )
    }

    /** An account-wide change on any reachable machine, this device's first. */
    private suspend fun <T> accountWide(
        accountId: String,
        block: suspend (ProviderAccountServiceClient) -> T,
    ): T = onMachine(required(accountId), anyMachine(accountId), block)

    /**
     * A reachable machine for an account-wide call: the one that created [accountId] while the
     * replica has not shown it yet (others may not have its record), else this device's first.
     */
    private fun anyMachine(accountId: String): String {
        val reachable = accounts.view.value.reachable
        return accounts.createdOn(accountId)?.takeIf { id -> reachable.any { it.id == id } }
            ?: reachable.firstOrNull()?.id
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "No machine is online; try again when one is.",
            )
    }

    /** [block] on [machineId] while [accountId] shows a change in flight. */
    private suspend fun <T> onMachine(
        accountId: String,
        machineId: String,
        block: suspend (ProviderAccountServiceClient) -> T,
    ): T {
        required(accountId)
        if (machineId.isEmpty()) throw CoreException(FailureKind.PERMANENT, "Choose a machine.")
        if (accountId in accounts.view.value.mutating)
            throw CoreException(
                FailureKind.TRANSIENT,
                "Another change to this account is still in progress.",
            )
        val generation = accounts.generation
        accounts.update { it.copy(mutating = it.mutating + accountId, error = null) }
        try {
            return machines.call(machineId) { api -> withDeadline(Deadlines.READ) { block(api) } }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            if (generation == accounts.generation)
                accounts.update { it.copy(error = providerProblem(error)) }
            throw error
        } finally {
            if (generation == accounts.generation)
                accounts.update { it.copy(mutating = it.mutating - accountId) }
        }
    }

    /** A reachable machine where [accountId] is signed in, this device's first. */
    private fun signedInMachine(accountId: String): String {
        val view = accounts.view.value
        val account = known(accountId)
        return view.reachable.firstOrNull { account.signedIn(it.id) }?.id
            ?: throw CoreException(
                FailureKind.TRANSIENT,
                "${account.label} isn't signed in on a machine that is online.",
            )
    }

    private fun known(accountId: String): ProviderAccountView =
        accounts.view.value.account(required(accountId))
            ?: throw CoreException(FailureKind.PERMANENT, "This account is no longer available.")

    private fun required(value: String): String = value.ifEmpty {
        throw CoreException(FailureKind.PERMANENT, "Choose an account.")
    }

    /** 1-60 characters on one line. */
    private fun label(value: String): String {
        val label = value.trim()
        if (label.isEmpty()) throw CoreException(FailureKind.PERMANENT, "Name the account.")
        if (label.any { it == '\n' || it == '\r' })
            throw CoreException(FailureKind.PERMANENT, "An account name is a single line.")
        if (label.codePointCount() > MAX_LABEL)
            throw CoreException(
                FailureKind.PERMANENT,
                "An account name has at most $MAX_LABEL characters.",
            )
        return label
    }

    private fun providerName(kind: ProviderKind): String? =
        when (kind) {
            ProviderKind.PROVIDER_KIND_CLAUDE -> ProviderKinds.CLAUDE
            ProviderKind.PROVIDER_KIND_CHATGPT -> ProviderKinds.CHATGPT
            else -> null
        }

    private fun methodName(method: ProviderLoginMethod): String? =
        when (method) {
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_CLAUDE_CODE ->
                ProviderKinds.METHOD_CLAUDE_CODE
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_CODEX -> ProviderKinds.METHOD_CODEX
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_SIWC -> ProviderKinds.METHOD_SIWC
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_HOST -> ProviderKinds.METHOD_HOST
            ProviderLoginMethod.PROVIDER_LOGIN_METHOD_ENVIRONMENT ->
                ProviderKinds.METHOD_ENVIRONMENT
            else -> null
        }

    private fun method(method: String): ProviderLoginMethod =
        when (method) {
            ProviderKinds.METHOD_CLAUDE_CODE ->
                ProviderLoginMethod.PROVIDER_LOGIN_METHOD_CLAUDE_CODE
            ProviderKinds.METHOD_CODEX -> ProviderLoginMethod.PROVIDER_LOGIN_METHOD_CODEX
            ProviderKinds.METHOD_SIWC -> ProviderLoginMethod.PROVIDER_LOGIN_METHOD_SIWC
            else -> ProviderLoginMethod.PROVIDER_LOGIN_METHOD_UNSPECIFIED
        }

    private fun String.codePointCount(): Int = count { !it.isLowSurrogate() }

    private companion object {
        const val MAX_LABEL = 60
    }
}
