package com.getdieter.core.providers

import com.getdieter.api.v1.KVEntry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** What a provider reported about an account at a verified sign-in. */
data class AccountIdentity(
    val email: String = "",
    val organization: String = "",
    val organizationId: String = "",
    val workspaceId: String = "",
    val subject: String = "",
    val plan: String = "",
)

/** One `provider-accounts` record: an account any machine may sign in to. */
data class AccountRecord(
    val id: String,
    /** [ProviderKinds.CLAUDE] or [ProviderKinds.CHATGPT]. */
    val provider: String,
    val label: String,
    /** claude-code, codex, siwc, host or environment. */
    val method: String,
    val identity: AccountIdentity = AccountIdentity(),
    val includeInSummary: Boolean = true,
    val createdAt: String = "",
    val createdBy: String = "",
    /** Claude only: Oh My Pi turns may use this login ([OmpAccounts]). */
    val ompAccess: Boolean = false,
)

data class UsageWindowRecord(
    /** five_hour, weekly, model or other. */
    val kind: String = "",
    val label: String = "",
    /** 0-100; null when the provider left it out. */
    val usedPercent: Double? = null,
    val resetsAt: String = "",
    val durationMinutes: Int = 0,
)

/** Plan limits as the provider reported them to one machine. */
data class UsageRecord(
    val plan: String = "",
    val observedAt: String = "",
    /** probe or turn. */
    val source: String = "",
    val windows: List<UsageWindowRecord> = emptyList(),
    val creditsBalance: String = "",
    val creditsUnlimited: Boolean = false,
    val resetCredits: Int = 0,
    /** signed_out, unsupported, rate_limited, or empty. */
    val unavailable: String = "",
)

data class TokenTotals(val input: Long = 0, val output: Long = 0, val total: Long = 0) {
    operator fun plus(other: TokenTotals) =
        TokenTotals(input + other.input, output + other.output, total + other.total)
}

/** Tokens Dieter's own turns used on an account from one machine (or summed over machines). */
data class TokenRecord(
    val fiveHour: TokenTotals = TokenTotals(),
    val sevenDay: TokenTotals = TokenTotals(),
    val observedAt: String = "",
)

/** One `provider-logins` record: the account's sign-in on one machine, written by that machine. */
data class LoginRecord(
    val accountId: String,
    /** The writing daemon; mapped to its machine ID by [ProviderAccounts]. */
    val daemonId: String,
    /** signed_in, signed_out, expired or failed. */
    val state: String,
    val method: String = "",
    val identity: AccountIdentity = AccountIdentity(),
    val verifiedAt: String = "",
    val errorCode: String = "",
    val errorMessage: String = "",
    val usage: UsageRecord? = null,
    val tokens: TokenRecord? = null,
) {
    val signedIn: Boolean
        get() = state == ProviderKinds.SIGNED_IN
}

/**
 * The three provider namespaces of the account view, decoded tolerantly: unknown fields are
 * ignored, records that cannot be read are skipped and counted in [skipped], deleted entries are
 * left out. The daemons validate strictly; a client only needs to show what it can read.
 */
data class ProviderRecords(
    val accounts: List<AccountRecord> = emptyList(),
    /** Provider → its default account ID. */
    val defaults: Map<String, String> = emptyMap(),
    val logins: List<LoginRecord> = emptyList(),
    val skipped: Int = 0,
    /** Accounts whose record is a tombstone: they were removed. */
    val removed: Set<String> = emptySet(),
) {
    companion object {
        const val ACCOUNTS = "provider-accounts"
        const val DEFAULTS = "provider-account-defaults"
        const val LOGINS = "provider-logins"

        /** Decodes [kv] (namespace → key → entry, as `AccountSnapshot.kv` holds it). */
        fun decode(kv: Map<String, Map<String, KVEntry>>): ProviderRecords =
            decode(kv[ACCOUNTS].orEmpty(), kv[DEFAULTS].orEmpty(), kv[LOGINS].orEmpty())

        fun decode(
            accounts: Map<String, KVEntry>,
            defaults: Map<String, KVEntry>,
            logins: Map<String, KVEntry>,
        ): ProviderRecords {
            var skipped = 0
            fun <T : Any> read(entries: Map<String, KVEntry>, parse: (String, JsonObject) -> T?) =
                entries.values.mapNotNull { entry ->
                    if (entry.deleted) return@mapNotNull null
                    val value = json(entry)?.let { parse(entry.key, it) }
                    if (value == null) skipped++
                    value
                }
            val decodedAccounts = read(accounts, ::account).sortedBy { it.id }
            val decodedDefaults =
                read(defaults) { key, value -> default(key, value)?.let { key to it } }.toMap()
            val decodedLogins =
                read(logins, ::login).sortedWith(compareBy({ it.accountId }, { it.daemonId }))
            return ProviderRecords(
                decodedAccounts,
                decodedDefaults,
                decodedLogins,
                skipped,
                removed = accounts.values.filter { it.deleted }.mapTo(HashSet()) { it.key },
            )
        }

        fun account(key: String, value: JsonObject): AccountRecord? {
            val provider = value.string("provider")
            if (key.isEmpty() || provider !in ProviderKinds.ALL) return null
            return AccountRecord(
                id = key,
                provider = provider,
                label = value.string("label").trim().ifEmpty { "Account" },
                method = value.string("method").ifEmpty { ProviderKinds.defaultMethod(provider) },
                identity = identity(value.obj("identity")),
                includeInSummary = value.bool("includeInSummary") ?: true,
                createdAt = value.string("createdAt"),
                createdBy = value.string("createdBy"),
                ompAccess = provider == ProviderKinds.CLAUDE && value.bool("ompAccess") == true,
            )
        }

        fun default(key: String, value: JsonObject): String? =
            value.string("accountId").takeIf { key in ProviderKinds.ALL && it.isNotEmpty() }

        /** Keys are `<accountId>.<daemonId>`; account IDs never contain a dot. */
        fun login(key: String, value: JsonObject): LoginRecord? {
            val accountId = key.substringBefore('.', "")
            val daemonId = key.substringAfter('.', "")
            val state = value.string("state")
            if (accountId.isEmpty() || daemonId.isEmpty() || state.isEmpty()) return null
            val error = value.obj("error")
            return LoginRecord(
                accountId = accountId,
                daemonId = daemonId,
                state = state,
                method = value.string("method"),
                identity = identity(value.obj("identity")),
                verifiedAt = value.string("verifiedAt"),
                errorCode = error?.string("code").orEmpty(),
                errorMessage = error?.string("message").orEmpty(),
                usage = value.obj("usage")?.let(::usage),
                tokens = value.obj("dieterTokens")?.let(::tokens),
            )
        }

        private fun identity(value: JsonObject?): AccountIdentity =
            if (value == null) AccountIdentity()
            else
                AccountIdentity(
                    email = value.string("email"),
                    organization = value.string("organization"),
                    organizationId = value.string("organizationId"),
                    workspaceId = value.string("workspaceId"),
                    subject = value.string("subject"),
                    plan = value.string("plan"),
                )

        private fun usage(value: JsonObject): UsageRecord {
            val credits = value.obj("credits")
            return UsageRecord(
                plan = value.string("plan"),
                observedAt = value.string("observedAt"),
                source = value.string("source"),
                windows =
                    (value["windows"] as? JsonArray)
                        .orEmpty()
                        .mapNotNull { (it as? JsonObject)?.let(::window) }
                        .take(MAX_WINDOWS),
                creditsBalance = credits?.string("balance").orEmpty(),
                creditsUnlimited = credits?.bool("unlimited") ?: false,
                resetCredits = value.obj("resetCredits")?.long("available")?.toInt() ?: 0,
                unavailable = value.string("unavailable"),
            )
        }

        private fun window(value: JsonObject) =
            UsageWindowRecord(
                kind = value.string("kind"),
                label = value.string("label"),
                usedPercent = value.double("usedPercent"),
                resetsAt = value.string("resetsAt"),
                durationMinutes = value.long("durationMinutes")?.toInt() ?: 0,
            )

        private fun tokens(value: JsonObject) =
            TokenRecord(
                fiveHour = totals(value.obj("fiveHour")),
                sevenDay = totals(value.obj("sevenDay")),
                observedAt = value.string("observedAt"),
            )

        private fun totals(value: JsonObject?) =
            TokenTotals(
                input = value?.long("input") ?: 0,
                output = value?.long("output") ?: 0,
                total = value?.long("total") ?: 0,
            )

        private fun json(entry: KVEntry): JsonObject? =
            if (entry.value_json.size == 0) null
            else
                runCatching { Json.parseToJsonElement(entry.value_json.utf8()) as? JsonObject }
                    .getOrNull()

        private fun JsonObject.primitive(key: String): JsonPrimitive? = get(key) as? JsonPrimitive

        private fun JsonObject.string(key: String): String =
            primitive(key)?.takeIf { it.isString }?.content.orEmpty()

        private fun JsonObject.bool(key: String): Boolean? = primitive(key)?.booleanOrNull

        private fun JsonObject.double(key: String): Double? =
            primitive(key)?.takeIf { !it.isString }?.doubleOrNull

        private fun JsonObject.long(key: String): Long? =
            primitive(key)
                ?.takeIf { !it.isString }
                ?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }

        private fun JsonObject.obj(key: String): JsonObject? = get(key) as? JsonObject

        /** The daemons keep at most this many windows per record. */
        private const val MAX_WINDOWS = 16
    }
}

/** Provider names, methods and login states shared by every provider surface. */
object ProviderKinds {
    const val CLAUDE = "claude"
    const val CHATGPT = "chatgpt"

    /** In the order every list shows them: Claude, then ChatGPT. */
    val ALL = listOf(CLAUDE, CHATGPT)

    const val METHOD_CLAUDE_CODE = "claude-code"
    const val METHOD_CODEX = "codex"
    const val METHOD_SIWC = "siwc"
    const val METHOD_HOST = "host"
    const val METHOD_ENVIRONMENT = "environment"

    const val SIGNED_IN = "signed_in"
    const val SIGNED_OUT = "signed_out"
    const val EXPIRED = "expired"
    const val FAILED = "failed"

    /** A machine without a login record for the account. */
    const val NOT_SIGNED_IN = "not_signed_in"

    /** The provider whose accounts an agent harness runs on; null for harnesses without them. */
    fun forHarness(harness: String): String? =
        when (harness) {
            "claude-code" -> CLAUDE
            "codex" -> CHATGPT
            else -> null
        }

    /**
     * The provider whose accounts [harness] runs [model] on: Oh My Pi follows its model's provider
     * ([OmpAccounts.provider]), other harnesses [forHarness].
     */
    fun forSelection(harness: String, model: String): String? =
        if (harness == OmpAccounts.HARNESS) OmpAccounts.provider(model) else forHarness(harness)

    fun name(provider: String): String =
        when (provider) {
            CLAUDE -> "Claude"
            CHATGPT -> "ChatGPT"
            else -> provider.replaceFirstChar { it.uppercaseChar() }.ifEmpty { "Provider" }
        }

    /** The method a new account signs in with when none is chosen. */
    fun defaultMethod(provider: String): String =
        if (provider == CHATGPT) METHOD_CODEX else METHOD_CLAUDE_CODE

    /** Methods a person may create an account with; host and environment are adopted only. */
    fun creatableMethods(provider: String): List<String> =
        when (provider) {
            CLAUDE -> listOf(METHOD_CLAUDE_CODE)
            CHATGPT -> listOf(METHOD_CODEX, METHOD_SIWC)
            else -> emptyList()
        }

    /** Dieter runs this method's sign-in; host and environment follow the machine itself. */
    fun signsIn(method: String): Boolean =
        method == METHOD_CLAUDE_CODE || method == METHOD_CODEX || method == METHOD_SIWC

    /**
     * "Claude Code sign-in", "Codex sign-in", "Sign in with ChatGPT", "Machine login", "API key".
     */
    fun methodLabel(method: String): String =
        when (method) {
            METHOD_CLAUDE_CODE -> "Claude Code sign-in"
            METHOD_CODEX -> "Codex sign-in"
            METHOD_SIWC -> "Sign in with ChatGPT"
            METHOD_HOST -> "Machine login"
            METHOD_ENVIRONMENT -> "API key"
            else -> method
        }

    /** "Max", "Plus": a plan as the provider names it, capitalized. */
    fun planName(plan: String): String = plan.trim().replaceFirstChar { it.uppercaseChar() }
}
