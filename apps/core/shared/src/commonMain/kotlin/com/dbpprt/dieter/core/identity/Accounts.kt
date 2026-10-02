package com.dbpprt.dieter.core.identity

import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.state.AccountsState
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The configured gateways and per-gateway choices. */
data class Accounts(
    val gateways: List<Gateway>,
    val active: Gateway,
    /** Gateway origin → the machine whose feed the client attaches to. */
    val preferredMachine: Map<String, String> = emptyMap(),
    /** Gateway origin → the user asked to stay connected. Defaults to true. */
    val desiredConnected: Map<String, Boolean> = emptyMap(),
) {
    val wantsConnection: Boolean get() = desiredConnected[active.origin] ?: true
}

/** Persists [Accounts]; the one owner of gateway configuration. */
class AccountStore(private val storage: CoreStorage) {
    private val mutableState = MutableStateFlow(load())
    val state: StateFlow<Accounts> = mutableState.asStateFlow()

    private fun load(): Accounts {
        val saved = runCatching { storage.read(FILE)?.let(AccountsState.ADAPTER::decode) }.getOrNull()
        val gateways = saved?.gateways?.map { it.toGateway() }?.distinctBy { it.origin }?.takeIf { it.isNotEmpty() }
            ?: listOf(Gateway.DEFAULT)
        val activeOrigin = saved?.active_origin?.let { origin -> gateways.firstOrNull { it.origin == origin } }
        return Accounts(
            gateways = gateways,
            active = activeOrigin ?: gateways.first(),
            preferredMachine = saved?.preferred_machine.orEmpty(),
            desiredConnected = saved?.desired_connected.orEmpty(),
        )
    }

    /**
     * Replaces the gateway list. Gateways must be unique and, unless on
     * loopback, use TLS. The active gateway is kept when still present.
     */
    fun setGateways(gateways: List<Gateway>, activeOrigin: String? = null) {
        if (gateways.isEmpty()) throw CoreException(FailureKind.PERMANENT, "At least one Dieter gateway is required.")
        if (gateways.map { it.origin.lowercase() }.distinct().size != gateways.size) {
            throw CoreException(FailureKind.PERMANENT, "Gateway addresses must be unique.")
        }
        gateways.firstOrNull { !it.permitted }?.let {
            throw CoreException(FailureKind.PERMANENT, "Remote gateways must use HTTPS (${it.host}).")
        }
        val current = mutableState.value
        val active = gateways.firstOrNull { it.origin == activeOrigin }
            ?: gateways.firstOrNull { it.origin == current.active.origin }
            ?: gateways.first()
        save(current.copy(gateways = gateways, active = active))
    }

    fun select(origin: String) {
        val current = mutableState.value
        val gateway = current.gateways.firstOrNull { it.origin == origin } ?: return
        if (gateway != current.active) save(current.copy(active = gateway))
    }

    fun preferMachine(daemonId: String?) {
        val current = mutableState.value
        val origin = current.active.origin
        val next = if (daemonId == null) current.preferredMachine - origin else current.preferredMachine + (origin to daemonId)
        if (next != current.preferredMachine) save(current.copy(preferredMachine = next))
    }

    fun setDesiredConnected(value: Boolean) {
        val current = mutableState.value
        save(current.copy(desiredConnected = current.desiredConnected + (current.active.origin to value)))
    }

    private fun save(accounts: Accounts) {
        storage.write(
            FILE,
            AccountsState.ADAPTER.encode(
                AccountsState(
                    gateways = accounts.gateways.map { it.record() },
                    active_origin = accounts.active.origin,
                    preferred_machine = accounts.preferredMachine,
                    desired_connected = accounts.desiredConnected,
                ),
            ),
        )
        mutableState.value = accounts
    }

    private companion object {
        const val FILE = "accounts.pb"
    }
}
