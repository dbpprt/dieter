package com.getdieter.core.notifications

import com.getdieter.api.gateway.v1.SetPushDeviceRequest
import com.getdieter.core.platform.DeviceKeys
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.session.GatewaySession
import com.getdieter.core.trust.DeviceTrust
import com.getdieter.core.trust.TrustState
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.toByteString

/** Registers an OS route against the current revocable account session. */
class PushNotifications(
    private val sink: AttentionNotificationSink,
    private val log: CoreLogger,
    private val keys: DeviceKeys,
    private val trust: DeviceTrust,
) {
    private val revision = MutableStateFlow(0L)

    fun refresh() {
        revision.update { it + 1 }
    }

    suspend fun run(sessions: StateFlow<GatewaySession?>) {
        combine(sessions, revision, trust.view) { session, _, view -> session to view }
            .collectLatest { (session, view) ->
                if (session == null || view.state != TrustState.TRUSTED || view.roster == null) {
                    sink.registered(false)
                    return@collectLatest
                }
                sink.registered(false)
                var attempt = 0
                while (true) {
                    try {
                        withTimeoutOrNull(15.seconds) {
                            val device =
                                sink.device(view.roster.account) ?: return@withTimeoutOrNull
                            val response =
                                session.client
                                    .SetPushDevice()
                                    .execute(
                                        SetPushDeviceRequest(
                                            token = device.token,
                                            public_key = device.publicKey,
                                            sandbox = device.sandbox,
                                            provider = device.provider,
                                            device_id = view.deviceId,
                                            signature =
                                                keys
                                                    .sign(
                                                        "dieter-push-key-v1\n${view.roster.account}\n${view.deviceId}\n${device.publicKey.base64()}"
                                                            .encodeToByteArray()
                                                    )
                                                    .toByteString(),
                                        )
                                    )
                            sink.registered(response.available)
                        } ?: error("Push registration timed out")
                        break
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (failure: Throwable) {
                        log.warn("push", "Push registration unavailable")
                        if (++attempt >= 3) break
                        delay((attempt * 5).seconds)
                    }
                }
            }
    }

    suspend fun unregister(session: GatewaySession?) {
        if (session == null) return
        try {
            withTimeoutOrNull(5.seconds) {
                session.client.SetPushDevice().execute(SetPushDeviceRequest())
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            log.warn("push", "Push unregistration unavailable")
        }
        sink.registered(false)
    }
}
