package com.getdieter.core.routing

import com.getdieter.api.gateway.v1.GatewayServiceClient
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.SilentLogger
import com.getdieter.core.testing.OfflineTransport
import com.getdieter.core.trust.DeviceTrust
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.time.Clock
import kotlinx.coroutines.test.runTest

/** A route is selected only for a trusted device and a machine in its pinned roster. */
class RouteTrustTest {
    /** A gateway that fails the test if any route RPC reaches it. */
    private val gateway =
        Proxy.newProxyInstance(
            GatewayServiceClient::class.java.classLoader,
            arrayOf(GatewayServiceClient::class.java),
        ) { _, method, _ ->
            error("an untrusted selection called ${method.name}")
        } as GatewayServiceClient

    private fun selector(reason: String) =
        RouteSelector(
            OfflineTransport,
            OfflineTransport,
            null,
            { throw CoreException(com.getdieter.core.runtime.FailureKind.TRANSIENT, reason) },
            RoutingPolicy(false),
            WebRtcCooldown(Clock.System),
            SilentLogger,
        )

    @Test
    fun anUntrustedDeviceOrMachineNeverAsksTheGatewayForARoute() = runTest {
        val access = GatewayAccess("https://gateway.test", "session", "0.0.0-dev.0")
        for (reason in listOf(DeviceTrust.NOT_TRUSTED, DeviceTrust.MACHINE_NOT_TRUSTED)) {
            val failure =
                assertFailsWith<CoreException> {
                    selector(reason).select(gateway, access, "d_studio")
                }
            assertEquals(reason, failure.message)
        }
    }
}
