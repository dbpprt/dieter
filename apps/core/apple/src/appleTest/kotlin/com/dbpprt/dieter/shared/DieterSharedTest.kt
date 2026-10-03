package com.dbpprt.dieter.shared

import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Update
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.runBlocking
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID

/** The façade as Swift reaches it: nothing a caller sends may throw across the Objective-C boundary. */
class DieterSharedTest {
    private val directory = NSTemporaryDirectory() + "dieter-shared-" + NSUUID().UUIDString
    private val shared = DieterShared(
        SharedConfiguration(
            stateDirectory = directory, clientVersion = "0.0.0-dev.0", oauthRedirectUri = "dieter-test://oauth/callback", clientIdPrefix = "test",
            includeLoopbackRoutes = false, compactTranscripts = true, screenClientName = "Test", desktopScreens = false,
        ),
        SharedExtensions(rpc = OfflineRpc, secureStore = MemoryStore(), settings = MemorySettings(), http = OfflineHttp, signatures = null, logger = null, notifications = null),
    )

    @AfterTest
    fun tearDown() {
        runBlocking { shared.shutdown() }
        NSFileManager.defaultManager.removeItemAtPath(directory, null)
    }

    @Test
    fun aSliceThisCoreDoesNotKnowIsOneFailureUpdate() {
        for (slice in listOf(9999, Slice.SLICE_UNSPECIFIED.value)) {
            val updates = mutableListOf<Update>()
            val subscription = shared.observe(slice, "scope", object : SharedObserver {
                override fun update(bytes: NSData) {
                    updates += Update.ADAPTER.decode(bytes.toByteArray())
                }
            })
            subscription.close()
            val update = updates.single()
            assertEquals(Failure.Kind.KIND_INVALID, update.failure?.kind, "slice $slice")
            assertEquals(Slice.SLICE_UNSPECIFIED, update.slice)
            assertEquals("scope", update.scope)
            assertEquals(1L, update.sequence)
        }
    }

    private object OfflineRpc : NativeRpcBridge {
        override fun unary(target: NativeRpcTarget, path: String, request: NSData, completion: NativeUnaryCompletion): NativeRpcCancellable {
            completion.failed(14, "offline")
            return Cancelled
        }

        override fun serverStreaming(target: NativeRpcTarget, path: String, request: NSData, observer: NativeStreamObserver): NativeRpcCancellable {
            observer.closed(14, "offline")
            return Cancelled
        }

        override fun release(channelId: String) = Unit
    }

    private object Cancelled : NativeRpcCancellable {
        override fun cancel() = Unit
    }

    private object OfflineHttp : NativeHttp {
        override fun postJson(url: String, body: String, completion: NativeHttpCompletion) = completion.completed(0, "")
    }

    private class MemoryStore : NativeSecureStore {
        private val values = HashMap<String, String>()
        override fun read(key: String): String? = values[key]
        override fun write(key: String, value: String) { values[key] = value }
        override fun delete(key: String) { values.remove(key) }
    }

    private class MemorySettings : NativeSettings {
        private val values = HashMap<String, String>()
        override fun string(key: String): String? = values[key]
        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
