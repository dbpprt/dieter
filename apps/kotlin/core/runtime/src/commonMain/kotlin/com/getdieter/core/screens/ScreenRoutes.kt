package com.getdieter.core.screens

import com.getdieter.api.gateway.v1.DaemonRef
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.session.MachineSessions

/**
 * Screen signaling over the machine's shared data plane, whose TLS is pinned to the machine's
 * roster key; the same key verifies the screen binding. Every attempt fetches fresh ICE servers, so
 * an expired TURN envelope is never reused. Tokens renew per RPC, so the route needs no planned
 * refresh; a transport failure retires the plane.
 */
fun MachineSessions.screenRoutes(daemonId: String): ScreenRouteFactory = {
    val gateway =
        gatewaySession ?: throw CoreException(FailureKind.TRANSIENT, "Not connected to a gateway.")
    val rtc = gateway.client.GetRTCConfiguration().execute(DaemonRef(daemon_id = daemonId))
    val plane = plane(daemonId)
    ScreenRoute(
        client = plane.client,
        daemonPublicKey = plane.daemonKey,
        rtc = rtc,
        label = plane.kind.label,
        onFailure = { error ->
            if (MachineSessions.isTransportFailure(error)) invalidate(daemonId, plane)
        },
    )
}
