package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.gateway.v1.DaemonRef
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.session.MachineSessions

/**
 * Screen signaling over the machine's shared data plane. Every attempt
 * resolves the enrolled certificate and fetches fresh ICE servers, so an
 * expired TURN envelope is never reused. Tokens renew per RPC, so the route
 * needs no planned refresh; a transport failure retires the plane.
 */
fun MachineSessions.screenRoutes(daemonId: String): ScreenRouteFactory = {
    val gateway = gatewaySession ?: throw CoreException(FailureKind.TRANSIENT, "Not connected to a gateway.")
    val resolved = gateway.client.ResolveDaemonRoute().execute(DaemonRef(daemon_id = daemonId))
    if (resolved.daemon_certificate_pem.size == 0) throw CoreException(FailureKind.PERMANENT, "This machine has no enrolled certificate.")
    val rtc = gateway.client.GetRTCConfiguration().execute(DaemonRef(daemon_id = daemonId))
    val plane = plane(daemonId)
    ScreenRoute(
        client = plane.client, certificatePem = resolved.daemon_certificate_pem.utf8(), rtc = rtc, label = plane.kind.label,
        onFailure = { error -> if (MachineSessions.isTransportFailure(error)) invalidate(daemonId, plane) },
    )
}
