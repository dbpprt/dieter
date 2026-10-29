package com.getdieter.core

import com.getdieter.api.v1.CreateConversationRequest
import com.getdieter.api.v1.MessagePart
import com.getdieter.api.v1.SendMessageRequest
import com.getdieter.api.v1.WatchConversationRequest
import com.getdieter.client.v1.ConversationSlice
import com.getdieter.client.v1.Slice
import com.getdieter.core.client.ClientApi
import com.getdieter.core.connection.SyncState
import com.getdieter.core.platform.DaemonTokenSource
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.RpcChannel
import com.getdieter.core.platform.RpcTransport
import com.getdieter.core.platform.SoftwareDeviceKeys
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.SliceFolds
import com.getdieter.core.testing.await
import com.getdieter.core.testing.jvmTestPlatform
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcClient
import com.squareup.wire.GrpcClientStreamingCall
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcMethod
import com.squareup.wire.GrpcServerStreamingCall
import com.squareup.wire.GrpcStatus
import com.squareup.wire.GrpcStreamingCall
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.produce
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first

/** The byte-only UI switches chats/cards, while real account and transcript streams race. */
class ConversationSyncEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private class Mirror(api: ClientApi, id: String) {
        val value = MutableStateFlow<ConversationSlice?>(null)
        private var sequence = 0L
        private var transcriptSequence = 0L
        val subscription =
            api.observe(Slice.SLICE_CONVERSATION, id) { update ->
                assertEquals(++sequence, update.sequence)
                val next =
                    update.conversation
                        ?: update.conversation_delta?.let {
                            SliceFolds.apply(checkNotNull(value.value), it)
                        }
                        ?: error("conversation observation failed: $update")
                next.conversation?.let {
                    assertTrue(
                        it.last_seq >= transcriptSequence,
                        "switching or a delayed frame rolled back the transcript",
                    )
                    transcriptSequence = it.last_seq
                }
                value.value = next
            }
    }

    private fun ConversationSlice.hasReply(text: String) = messages.any { message ->
        message.role == "assistant" && message.parts.any { it.type == "text" && text in it.text }
    }

    @Test fun relayChatAndCardSwitchesKeepRecentTranscriptsLive() = e2e { verifySwitches(null) }

    @Test fun directChatAndCardSwitchesKeepRecentTranscriptsLive() = e2e { verifySwitches("live") }

    private suspend fun verifySwitches(route: String?) {
        val fixture = fixture(directRoute = route)
        val actor = runtime(fixture)
        val platform = jvmTestPlatform()
        val delayed = DelayedTranscripts(platform.transport)
        val observer =
            runtime(
                fixture,
                platform =
                    jvmTestPlatform(
                        deviceKeys = platform.deviceKeys as SoftwareDeviceKeys,
                        transport = delayed,
                    ),
            ) {
                it.copy(conversations = it.conversations.copy(maxOpen = 2))
            }
        observer.awaitSync(fixture.daemonId, SyncState.LIVE)
        actor.awaitLoaded(fixture)
        val cards =
            actor.onMachine(fixture.daemonId) { client ->
                (0..2).map { index ->
                    val request =
                        CreateConversationRequest(
                            project_id = fixture.projectId,
                            board_id = if (index == 0) fixture.boardId else "",
                            lane = "todo",
                            title = "Switch $index",
                            provider = "mock",
                            model = "mock",
                            workspace_mode = "project",
                            defer_start = true,
                        )
                    if (index == 0) client.CreateCard().execute(request)
                    else client.CreateChat().execute(request)
                }
            }
        observer.awaitSynced(*cards.map { it.id }.toTypedArray())
        val api = ClientApi(observer)
        suspend fun send(id: String, text: String) =
            actor.onMachine(fixture.daemonId) {
                it.SendMessage()
                    .execute(
                        SendMessageRequest(
                            card_id = id,
                            parts = listOf(MessagePart(type = "text", text = text)),
                        )
                    )
            }
        val first = Mirror(api, cards[0].id)
        first.value.await { it?.conversation != null && !it.syncing }
        send(cards[0].id, "before switching")
        first.value.await {
            it?.hasReply("before switching") == true && !it.syncing && it.state?.working == false
        }
        val warm = observer.onCore { observer.conversations.session(cards[0].id)!! }
        first.subscription.close()

        val second = Mirror(api, cards[1].id)
        second.value.await { it?.conversation != null && !it.syncing }
        send(cards[0].id, "while another chat is open")
        warm.view.await { view ->
            view.messages.any {
                it.role == "assistant" && it.parts.any { "while another chat is open" in it.text }
            } && !view.syncing && view.conversation?.status == "idle"
        }
        val newest = warm.view.value.transcript.lastSeq
        val returned = Mirror(api, cards[0].id)
        second.subscription.close()
        val initial = returned.value.await { it?.conversation != null }!!
        assertTrue(
            initial.hasReply("while another chat is open"),
            "the first reopened slice is already current",
        )
        assertTrue(initial.conversation!!.last_seq >= newest)
        assertSame(warm, observer.onCore { observer.conversations.session(cards[0].id) })
        returned.subscription.close()

        // The warm set is bounded. A third open evicts the least recently observed chat.
        val third = Mirror(api, cards[2].id)
        third.value.await { it?.conversation != null && !it.syncing }
        assertNull(observer.onCore { observer.conversations.session(cards[1].id) })
        send(cards[1].id, "arrived after eviction")
        observer.workspace.state.await { view ->
            view.activities[cards[1].id]?.messages?.any { message ->
                message.role == "assistant" &&
                    message.parts.any { "arrived after eviction" in it.text }
            } == true && view.activities[cards[1].id]?.status == "idle"
        }
        // Hold only transcript frames. Account changes and unary reads still use the real routes.
        delayed.held.value = setOf(cards[1].id)
        val cached = Mirror(api, cards[1].id)
        val pending = cached.value.await { it?.conversation != null }!!
        assertTrue(pending.syncing, "cached data is not current merely because a watch was opened")
        assertFalse(pending.hasReply("arrived after eviction"))
        val refreshed =
            cached.value.await(30.seconds) {
                it?.hasReply("arrived after eviction") == true && !it.syncing
            }!!
        assertTrue(
            refreshed.refreshed_at_millis > 0,
            "the cached-open fallback read catches up without any stream frame",
        )
        delayed.held.value = emptySet()
        send(cards[1].id, "after delayed frames")
        cached.value.await { it?.hasReply("after delayed frames") == true && !it.syncing }
        cached.subscription.close()
        third.subscription.close()

        // A warm session that stopped on a permanent error must be reopenable too.
        delayed.failed.value = setOf(cards[0].id)
        val failed = Mirror(api, cards[0].id)
        failed.value.await { it?.error?.contains("updates paused") == true && !it.syncing }
        val stopped = observer.onCore { observer.conversations.session(cards[0].id) }
        failed.subscription.close()
        delayed.failed.value = emptySet()
        val retried = Mirror(api, cards[0].id)
        retried.value.await {
            it?.hasReply("while another chat is open") == true && !it.syncing && it.error.isEmpty()
        }
        assertNotSame(stopped, observer.onCore { observer.conversations.session(cards[0].id) })
        retried.subscription.close()
    }
}

/** Delays delivery, including the first frame, without changing production routing or RPC data. */
private class DelayedTranscripts(private val delegate: RpcTransport) : RpcTransport {
    val held = MutableStateFlow<Set<String>>(emptySet())
    val failed = MutableStateFlow<Set<String>>(emptySet())

    override fun gateway(access: GatewayAccess) = delegate.gateway(access)

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel {
        val channel = delegate.direct(target, tokens)
        val client = channel.client
        return RpcChannel(
            object : GrpcClient() {
                override fun <S : Any, R : Any> newCall(method: GrpcMethod<S, R>): GrpcCall<S, R> =
                    client.newCall(method)

                override fun <S : Any, R : Any> newStreamingCall(
                    method: GrpcMethod<S, R>
                ): GrpcStreamingCall<S, R> = client.newStreamingCall(method)

                override fun <S : Any, R : Any> newClientStreamingCall(
                    method: GrpcMethod<S, R>
                ): GrpcClientStreamingCall<S, R> = client.newClientStreamingCall(method)

                override fun <S : Any, R : Any> newServerStreamingCall(
                    method: GrpcMethod<S, R>
                ): GrpcServerStreamingCall<S, R> {
                    val call = client.newServerStreamingCall(method)
                    return object : GrpcServerStreamingCall<S, R> by call {
                        override suspend fun executeIn(
                            scope: CoroutineScope,
                            request: S,
                        ): ReceiveChannel<R> {
                            if (
                                request is WatchConversationRequest &&
                                    request.card_id in failed.value
                            )
                                throw GrpcException(
                                    GrpcStatus.PERMISSION_DENIED,
                                    "Test stream refused",
                                )
                            val frames = call.executeIn(scope, request)
                            if (request !is WatchConversationRequest) return frames
                            return scope.produce {
                                for (frame in frames) {
                                    held.first { request.card_id !in it }
                                    send(frame)
                                }
                            }
                        }
                    }
                }
            },
            channel::close,
        )
    }
}
