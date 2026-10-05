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

    /** Makes [gateway] active, adding it when its origin is new ("Custom" when unnamed) and renaming it to a non-blank name otherwise. */
    fun use(gateway: Gateway) {
        if (!gateway.permitted) throw CoreException(FailureKind.PERMANENT, "Remote gateways must use HTTPS (${gateway.host}).")
        val current = mutableState.value
        val existing = current.gateways.firstOrNull { it.origin == gateway.origin }
        val active = existing?.let { if (gateway.name.isBlank()) it else it.copy(name = gateway.name) } ?: gateway.copy(name = gateway.name.ifBlank { "Custom" })
        val gateways = if (existing == null) current.gateways + active else current.gateways.map { if (it.origin == active.origin) active else it }
        if (gateways != current.gateways || active != current.active) save(current.copy(gateways = gateways, active = active))
    }

    /** Removes the gateway at [origin]; the last one stays. The first remaining one becomes active in place of a removed active one. */
    fun remove(origin: String) {
        val current = mutableState.value
        if (current.gateways.none { it.origin == origin }) return
        if (current.gateways.size == 1) throw CoreException(FailureKind.PERMANENT, "At least one Dieter gateway is required.")
        val gateways = current.gateways.filter { it.origin != origin }
        val active = current.active.takeIf { it.origin != origin } ?: gateways.first()
        save(current.copy(gateways = gateways, active = active, desiredConnected = current.desiredConnected - origin))
    }

    fun select(origin: String) {
        val current = mutableState.value
        val gateway = current.gateways.firstOrNull { it.origin == origin } ?: return
        if (gateway != current.active) save(current.copy(active = gateway))
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
