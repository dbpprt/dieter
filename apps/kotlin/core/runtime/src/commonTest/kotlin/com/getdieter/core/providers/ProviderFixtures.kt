package com.getdieter.core.providers

import com.getdieter.api.v1.KVEntry
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Provider KV records and views as the account replica holds them, for tests. */
object ProviderFixtures {
    const val CLAUDE_WORK = "pa_aaaaaaaaaaaaaaaaaaaaaaaaaa"
    const val CLAUDE_HOME = "pa_bbbbbbbbbbbbbbbbbbbbbbbbbb"
    const val CHATGPT_TEAM = "pa_cccccccccccccccccccccccccc"

    fun entry(namespace: String, key: String, json: String?, deleted: Boolean = false) =
        KVEntry(
            namespace = namespace,
            key = key,
            value_json = json?.encodeUtf8() ?: ByteString.EMPTY,
            deleted = deleted,
        )

    fun account(
        id: String,
        provider: String,
        label: String,
        method: String = ProviderKinds.defaultMethod(provider),
        email: String = "",
        included: Boolean = true,
    ) =
        entry(
            ProviderRecords.ACCOUNTS,
            id,
            """{"provider":"$provider","label":"$label","method":"$method",""" +
                """"identity":{"email":"$email"},"includeInSummary":$included,""" +
                """"createdAt":"2026-11-14T10:00:00Z","createdBy":"d1"}""",
        )

    fun default(provider: String, accountId: String) =
        entry(ProviderRecords.DEFAULTS, provider, """{"accountId":"$accountId"}""")

    fun login(
        accountId: String,
        daemonId: String,
        state: String = ProviderKinds.SIGNED_IN,
        usage: String? = null,
        tokens: String? = null,
        email: String = "",
        verifiedAt: String = "2026-11-14T11:58:00Z",
        error: String? = null,
    ) =
        entry(
            ProviderRecords.LOGINS,
            "$accountId.$daemonId",
            buildString {
                append("""{"state":"$state","method":"claude-code",""")
                append(""""identity":{"email":"$email"},"verifiedAt":"$verifiedAt"""")
                if (error != null)
                    append(""","error":{"code":"identity_mismatch","message":"$error"}""")
                if (usage != null) append(""","usage":$usage""")
                if (tokens != null) append(""","dieterTokens":$tokens""")
                append("}")
            },
        )

    /** Usage observed at [observedAt] with one window per used percentage. */
    fun usage(
        observedAt: String,
        vararg used: Pair<String, Double>,
        plan: String = "max",
        resetCredits: Int = 0,
    ): String =
        """{"plan":"$plan","observedAt":"$observedAt","source":"probe","windows":[""" +
            used.joinToString(",") { (kind, percent) ->
                """{"kind":"$kind","usedPercent":$percent,"resetsAt":"2026-11-14T15:00:00Z"}"""
            } +
            """],"resetCredits":{"available":$resetCredits}}"""

    fun tokens(fiveHour: Long, sevenDay: Long, observedAt: String = "2026-11-14T11:00:00Z") =
        """{"fiveHour":{"input":0,"output":0,"total":$fiveHour},""" +
            """"sevenDay":{"input":0,"output":0,"total":$sevenDay},"observedAt":"$observedAt"}"""

    fun kv(vararg entries: KVEntry): Map<String, Map<String, KVEntry>> =
        entries.groupBy { it.namespace }.mapValues { (_, list) -> list.associateBy { it.key } }

    val box = ProviderMachine("box", "box", online = true, reachable = true)
    val mac = ProviderMachine("mac", "mac", online = true, reachable = true, local = true)
    val laptop = ProviderMachine("laptop", "laptop", online = false, reachable = false)

    fun view(vararg entries: KVEntry, machines: List<ProviderMachine> = listOf(mac, box)) =
        ProvidersView.build(ProviderRecords.decode(kv(*entries)), machines)
}
