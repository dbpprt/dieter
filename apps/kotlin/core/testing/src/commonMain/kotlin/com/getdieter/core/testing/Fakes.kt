package com.getdieter.core.testing

import com.getdieter.core.connection.MachineDirectory
import com.getdieter.core.machines.MachineChoice
import com.getdieter.core.platform.DaemonTokenSource
import com.getdieter.core.platform.DeviceSettings
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.RpcChannel
import com.getdieter.core.platform.RpcTransport
import com.getdieter.core.platform.SecureStore
import com.getdieter.core.routing.RouteSelector
import com.getdieter.core.routing.RoutingPolicy
import com.getdieter.core.routing.WebRtcCooldown
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.session.MachineSessions
import com.getdieter.core.store.WorkspaceStore
import com.getdieter.core.sync.AccountSync
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

class MemorySecureStore : SecureStore {
    val values = LinkedHashMap<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String) {
        values[key] = value
    }

    override fun delete(key: String) {
        values.remove(key)
    }
}

class MemoryDeviceSettings : DeviceSettings {
    val values = LinkedHashMap<String, String>()

    override fun string(key: String): String? = values[key]

    override fun putString(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

/** A transport whose every route fails: a client that never connects. */
object OfflineTransport : RpcTransport {
    override fun gateway(access: GatewayAccess): RpcChannel = error("offline")

    override fun relay(access: GatewayAccess, daemonId: String): RpcChannel = error("offline")

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel =
        error("offline")
}

/** Machine sessions that never connect, for surfaces tested without a daemon. */
fun offlineSessions(): MachineSessions =
    MachineSessions(
        RouteSelector(
            OfflineTransport,
            null,
            RoutingPolicy(false),
            WebRtcCooldown(Clock.System),
            SilentLogger,
        ),
        CoroutineScope(Dispatchers.Unconfined),
    )

/** The machine choice of a client with no reachable machine, over [store]'s account view. */
fun unreachableChoice(store: WorkspaceStore): MachineChoice =
    MachineChoice(
        store,
        AccountSync(store, CoroutineScope(Dispatchers.Unconfined), Clock.System, SilentLogger),
        MutableStateFlow(MachineDirectory()),
        MutableStateFlow(emptyMap()),
    )

/** A wall clock tests move by hand. */
class ManualClock(var current: Instant = Instant.parse("2026-09-30T12:00:00Z")) : Clock {
    override fun now(): Instant = current
}

/** Waits in real time for [flow] to satisfy [predicate]; end-to-end tests use a live fixture. */
suspend fun <T> Flow<T>.await(
    timeout: Duration = 20.seconds,
    describe: () -> String = { "condition" },
    predicate: (T) -> Boolean,
): T =
    try {
        withTimeout(timeout) { first(predicate) }
    } catch (error: TimeoutCancellationException) {
        throw AssertionError("timed out after $timeout waiting for ${describe()}", error)
    }
