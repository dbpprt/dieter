package com.getdieter.apple

import com.getdieter.client.v1.Failure
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Update
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.runBlocking
import platform.Foundation.NSData
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID

/**
 * The façade as Swift reaches it: nothing a caller sends may throw across the Objective-C boundary.
 */
class DieterSharedTest {
    private val directory = NSTemporaryDirectory() + "dieter-shared-" + NSUUID().UUIDString
    private val shared =
        DieterShared(
            SharedConfiguration(
                stateDirectory = directory,
                clientVersion = "0.0.0-dev.0",
                oauthRedirectUri = "dieter-test://oauth/callback",
                clientIdPrefix = "test",
                includeLoopbackRoutes = false,
                compactTranscripts = true,
                screenClientName = "Test",
                desktopScreens = false,
            ),
            SharedExtensions(
                rpc = OfflineRpc,
                tunnels = OfflineTunnels,
                deviceKeys = FixedKeys,
                secureStore = MemoryStore(),
                settings = MemorySettings(),
                http = OfflineHttp,
                signatures = RejectingSignatures,
                logger = null,
                notifications = null,
            ),
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
            val subscription =
                shared.observe(
                    slice,
                    "scope",
                    object : SharedObserver {
                        override fun update(bytes: NSData) {
                            updates += Update.ADAPTER.decode(bytes.toByteArray())
                        }
                    },
                )
            subscription.close()
            val update = updates.single()
            assertEquals(Failure.Kind.KIND_INVALID, update.failure?.kind, "slice $slice")
            assertEquals(Slice.SLICE_UNSPECIFIED, update.slice)
            assertEquals("scope", update.scope)
            assertEquals(1L, update.sequence)
        }
    }

    private object OfflineRpc : NativeRpcBridge {
        override fun unary(
            target: NativeRpcTarget,
            path: String,
            request: NSData,
            completion: NativeUnaryCompletion,
        ): NativeRpcCancellable {
            completion.failed(14, "offline")
            return Cancelled
        }

        override fun serverStreaming(
            target: NativeRpcTarget,
            path: String,
            request: NSData,
            observer: NativeStreamObserver,
        ): NativeRpcCancellable {
            observer.closed(14, "offline")
            return Cancelled
        }

        override fun release(channelId: String) = Unit
    }

    private object OfflineTunnels : NativeTunnels {
        override fun open(
            url: String,
            sessionToken: String,
            clientVersion: String,
            daemonId: String,
            lane: Int,
            completion: NativeTunnelCompletion,
        ) = completion.completed(null, 14, "offline")
    }

    /** A P-256 public key that never signs: nothing in these tests connects. */
    private object FixedKeys : NativeDeviceKeys {
        override fun platform() = "macos"

        override fun deviceName() = "Test"

        override fun publicKey(): NSData =
            ("3059301306072a8648ce3d020106082a8648ce3d03010703420004cad3b4907225676285dd6fac57e1" +
                    "97fc1dad5282efe67fbefb13499298aa23b729bbc3605239971f5f4d152369700085ae58fec2de" +
                    "1b590a03f76052d467969b")
                .chunked(2)
                .map { it.toInt(16).toByte() }
                .toByteArray()
                .toNSData()

        override fun sign(message: NSData): NSData = NSData()

        override fun reset() = Unit
    }

    private object RejectingSignatures : NativeSignatures {
        override fun verifyEd25519(publicKey: NSData, message: NSData, signature: NSData) = false

        override fun verifyEcdsaP256(publicKey: NSData, message: NSData, signature: NSData) = false
    }

    private object Cancelled : NativeRpcCancellable {
        override fun cancel() = Unit
    }

    private object OfflineHttp : NativeHttp {
        override fun postJson(url: String, body: String, completion: NativeHttpCompletion) =
            completion.completed(0, "")
    }

    private class MemoryStore : NativeSecureStore {
        private val values = HashMap<String, String>()

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String) {
            values[key] = value
        }

        override fun delete(key: String) {
            values.remove(key)
        }
    }

    private class MemorySettings : NativeSettings {
        private val values = HashMap<String, String>()

        override fun string(key: String): String? = values[key]

        override fun putString(key: String, value: String?) {
            if (value == null) values.remove(key) else values[key] = value
        }
    }
}
