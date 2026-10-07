@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.ui.window.ComposeUIViewController
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.shared.DieterShared
import com.dbpprt.dieter.shared.SharedObserver
import kotlinx.cinterop.*
import kotlinx.coroutines.*
import platform.Foundation.*
import platform.UIKit.UIApplication
import platform.UIKit.UIViewController
import platform.posix.memcpy

/** One shared store/controller under the native SwiftUI glass chrome. */
class MobileHost(private val shared: DieterShared) {
    private val store =
        MobileStore(
            object : MobileCore {
                override suspend fun dispatch(command: Command): Result {
                    val reply =
                        Reply.ADAPTER.decode(shared.dispatch(command.encode().data()).bytesArray())
                    reply.failure?.let { error(it.message) }
                    return reply.result ?: error("The core returned no result.")
                }

                override fun observe(
                    slice: Slice,
                    scope: String,
                    receive: (Update) -> Unit,
                ): ClientSubscription {
                    val subscription =
                        shared.observe(
                            slice.value,
                            scope,
                            object : SharedObserver {
                                override fun update(bytes: NSData) {
                                    receive(Update.ADAPTER.decode(bytes.bytesArray()))
                                }
                            },
                        )
                    return ClientSubscription { subscription.close() }
                }
            }
        )

    fun controller(): UIViewController = ComposeUIViewController {
        MobileApp(
            store,
            apple = true,
            openUrl = { url ->
                NSURL.URLWithString(url)?.let {
                    UIApplication.sharedApplication.openURL(
                        it,
                        options = emptyMap<Any?, Any>(),
                        completionHandler = null,
                    )
                }
            },
        )
    }

    fun selectTab(index: Int) {
        store.back()
        store.tab.value = MobileTab.entries.getOrElse(index) { MobileTab.BOARD }
    }

    fun newTask() {
        store.creating.value = true
    }

    fun reconnect() = store.retry()

    fun completeSignIn(url: String) = store.completeSignIn(url)

    fun setForeground(active: Boolean) = store.action {
        store.core.dispatch(Command(set_foreground = SetForeground(active)))
    }

    fun adoptFixture(url: String, token: String) = store.action {
        store.core.dispatch(
            Command(adopt_session = AdoptSession(url, token, "Isolated Compose spike"))
        )
        store.agentSelection = com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
    }

    fun close() {
        store.close()
        MainScope().launch { shared.shutdown() }
    }
}

private fun ByteArray.data(): NSData =
    if (isEmpty()) NSData()
    else usePinned { NSData.create(bytes = it.addressOf(0), length = size.convert()) }

private fun NSData.bytesArray(): ByteArray =
    ByteArray(length.toInt()).also { result ->
        if (result.isNotEmpty()) result.usePinned { memcpy(it.addressOf(0), bytes, length) }
    }
