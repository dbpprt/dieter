package com.getdieter.core.providers

import com.getdieter.api.v1.ProviderAccountServiceClient
import com.getdieter.core.session.MachineSessions
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update

/** One machine of the account as provider surfaces show it. */
data class ProviderMachine(
    val id: String,
    val name: String,
    val online: Boolean,
    /** Online, compatible, and this device is trusted: it takes calls now. */
    val reachable: Boolean,
    /** This device runs it, so a browser here reaches its loopback callback. */
    val local: Boolean = false,
)

/** An account with its machines' sign-ins and usage. */
data class ProviderAccountView(
    val record: AccountRecord,
    val isDefault: Boolean = false,
    /** Machine ID → that machine's login; machines that left the account are dropped. */
    val logins: Map<String, LoginRecord> = emptyMap(),
    /** The freshest usage of any machine. */
    val usage: UsageRecord? = null,
    /** Dieter's own tokens, summed over machines. */
    val tokens: TokenRecord? = null,
    /** Created from this device; the account replica has not shown its record yet. */
    val pending: Boolean = false,
) {
    val id: String
        get() = record.id

    val provider: String
        get() = record.provider

    val label: String
        get() = record.label

    val method: String
        get() = record.method

    val includeInSummary: Boolean
        get() = record.includeInSummary

    /** The account's identity, else the first a machine verified. */
    val identity: AccountIdentity
        get() =
            record.identity.takeIf { it.email.isNotEmpty() }
                ?: logins.values.firstOrNull { it.identity.email.isNotEmpty() }?.identity
                ?: record.identity

    /** The plan the latest usage names, else the identity's. */
    val plan: String
        get() = usage?.plan?.ifBlank { null } ?: identity.plan

    fun signedIn(machineId: String): Boolean = logins[machineId]?.signedIn == true
}

/** Everything provider surfaces show; built from the account replica, machines and sessions. */
data class ProvidersView(
    /** Claude first, then ChatGPT; each by label. */
    val accounts: List<ProviderAccountView> = emptyList(),
    /** Provider → its default account ID. */
    val defaults: Map<String, String> = emptyMap(),
    /** This device's machine first, then by name. */
    val machines: List<ProviderMachine> = emptyList(),
    /** This device's sign-ins, live and finished. */
    val sessions: List<SignInSession> = emptyList(),
    /** Accounts with a change in flight. */
    val mutating: Set<String> = emptySet(),
    val error: String? = null,
    /** Records that could not be read. */
    val skipped: Int = 0,
) {
    fun account(id: String): ProviderAccountView? = accounts.firstOrNull { it.id == id }

    fun accounts(provider: String): List<ProviderAccountView> = accounts.filter {
        it.provider == provider
    }

    fun machine(id: String): ProviderMachine? = machines.firstOrNull { it.id == id }

    /** [id]'s name, else the start of its ID. */
    fun machineName(id: String): String = machine(id)?.name?.ifBlank { null } ?: id.take(8)

    val reachable: List<ProviderMachine>
        get() = machines.filter { it.reachable }

    /** This device's machine, when it runs a reachable one. */
    val local: ProviderMachine?
        get() = machines.firstOrNull { it.local && it.reachable }

    fun session(id: String): SignInSession? = sessions.firstOrNull { it.id == id }

    companion object {
        /**
         * The view of [records] on [machines]. Login records are keyed by daemon, which [machineOf]
         * maps to its machine; logins of machines the account no longer lists are dropped, unless
         * the machine list is not known yet (offline from cache). [pending] accounts show until the
         * records hold them or their tombstone.
         */
        fun build(
            records: ProviderRecords,
            machines: List<ProviderMachine>,
            pending: Collection<PendingAccount> = emptyList(),
            machineOf: (String) -> String = { it },
        ): ProvidersView {
            val listed = machines.mapTo(HashSet()) { it.id }
            val logins =
                records.logins
                    .map { it.copy(daemonId = machineOf(it.daemonId)) }
                    .filter { listed.isEmpty() || it.daemonId in listed }
                    .groupBy { it.accountId }
            val accounts =
                records.accounts
                    .map { record ->
                        val own = logins[record.id].orEmpty()
                        ProviderAccountView(
                            record = record,
                            isDefault = records.defaults[record.provider] == record.id,
                            logins = own.associateBy { it.daemonId },
                            usage = ProviderUsages.freshest(own),
                            tokens = ProviderUsages.tokens(own),
                        )
                    }
                    .plus(
                        pending
                            .filter { created ->
                                created.record.id !in records.removed &&
                                    records.accounts.none { it.id == created.record.id }
                            }
                            .map { created ->
                                val record = created.record
                                ProviderAccountView(
                                    record = record,
                                    isDefault =
                                        records.defaults[record.provider]?.let { it == record.id }
                                            ?: created.isDefault,
                                    pending = true,
                                )
                            }
                    )
                    .sortedWith(
                        compareBy(
                            { ProviderKinds.ALL.indexOf(it.provider) },
                            { it.label.lowercase() },
                            { it.id },
                        )
                    )
            return ProvidersView(
                accounts = accounts,
                defaults = records.defaults,
                machines = ordered(machines),
                skipped = records.skipped,
            )
        }

        /** This device's machine first, then by name. */
        fun ordered(machines: List<ProviderMachine>): List<ProviderMachine> =
            machines.sortedWith(compareBy({ !it.local }, { it.name.lowercase() }, { it.id }))
    }
}

/**
 * An account this device just created, shown until the account replica delivers its record (or its
 * tombstone), so the next command can address it at once.
 */
data class PendingAccount(
    val record: AccountRecord,
    /** The creating machine made it its provider's default. */
    val isDefault: Boolean = false,
    /** The machine that created it, which has its record first. */
    val createdOn: String = "",
)

/** The provider service of each machine. */
interface ProviderMachines {
    suspend fun <T> call(machineId: String, block: suspend (ProviderAccountServiceClient) -> T): T
}

/** [ProviderMachines] over this device's shared data planes. */
fun MachineSessions.providerMachines(): ProviderMachines =
    object : ProviderMachines {
        override suspend fun <T> call(
            machineId: String,
            block: suspend (ProviderAccountServiceClient) -> T,
        ): T = this@providerMachines.call(machineId, block)
    }

/**
 * The account's Claude and ChatGPT accounts as this device knows them: the replica's provider
 * records (so the view works offline from cache), the machines, this device's sign-in sessions
 * ([ProviderSignIn]) and changes in flight ([ProviderCommands]). Confined to the core dispatcher.
 */
class ProviderAccounts {
    private val mutableView = MutableStateFlow(ProvidersView())
    val view: StateFlow<ProvidersView> = mutableView.asStateFlow()

    /** Bumped when the account changes; work bound to an older one drops its results. */
    var generation = 0L
        private set

    private var records = ProviderRecords()
    private var machines = emptyList<ProviderMachine>()
    private val pending = LinkedHashMap<String, PendingAccount>()

    /** Follows the replica's [records] (machine IDs already mapped) and the [machines]. */
    suspend fun run(records: Flow<ProviderRecords>, machines: Flow<List<ProviderMachine>>) {
        combine(records, machines, ::Pair).collect { (next, listed) -> apply(next, listed) }
    }

    fun apply(records: ProviderRecords, machines: List<ProviderMachine>) {
        this.records = records
        this.machines = machines
        // The replica's record, or its tombstone, replaces an account this device created.
        pending.keys.removeAll { id ->
            id in records.removed || records.accounts.any { it.id == id }
        }
        publish()
    }

    /** Shows [account], which a machine just created, until the replica has its record. */
    fun created(account: PendingAccount) {
        val id = account.record.id
        if (id in records.removed || records.accounts.any { it.id == id }) return
        pending[id] = account
        publish()
    }

    /** Stops showing a created account the replica never delivered, e.g. after removing it. */
    fun forget(accountId: String) {
        if (pending.remove(accountId) != null) publish()
    }

    /** The machine that created [accountId] while the replica has not shown it yet. */
    fun createdOn(accountId: String): String? = pending[accountId]?.createdOn

    private fun publish() {
        val built = ProvidersView.build(records, machines, pending = pending.values)
        mutableView.update {
            built.copy(sessions = it.sessions, mutating = it.mutating, error = it.error)
        }
    }

    internal fun update(transform: (ProvidersView) -> ProvidersView) {
        mutableView.update(transform)
    }

    /** The account or gateway changed: forget everything. */
    fun reset() {
        generation++
        records = ProviderRecords()
        machines = emptyList()
        pending.clear()
        mutableView.value = ProvidersView()
    }
}
