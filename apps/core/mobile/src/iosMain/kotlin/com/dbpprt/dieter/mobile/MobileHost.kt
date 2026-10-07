@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.window.ComposeUIViewController
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.shared.DieterShared
import com.dbpprt.dieter.shared.SharedObserver
import kotlinx.cinterop.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import platform.Foundation.*
import platform.UIKit.UIApplication
import platform.UIKit.UIViewController
import platform.posix.memcpy

/** One shared store/controller under the native SwiftUI glass chrome. */
class MobileHost(private val shared: DieterShared, nativeViews: MobileNativeViews) {
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
            },
            preferences =
                MobilePreferences(
                    { NSUserDefaults.standardUserDefaults.stringForKey("compose-" + it) },
                    { key, value ->
                        NSUserDefaults.standardUserDefaults.setObject(
                            value,
                            forKey = "compose-" + key,
                        )
                    },
                ),
        )
    private val hostScope = MainScope()

    init {
        AppleNativeViews.factory = nativeViews
    }

    fun observeNavigation(observer: MobileNavigationObserver): MobileObservation {
        val job = hostScope.launch {
            combine(
                    store.tab,
                    store.selectedCard,
                    store.creating,
                    store.appearance,
                    store.palette,
                ) { tab, card, creating, appearance, palette ->
                    val primary =
                        if (tab == MobileTab.BOARD) MobileTab.PROJECTS
                        else if (tab in primaryTabs) tab else MobileTab.TOOLS
                    observer.changed(
                        primaryTabs.indexOf(primary),
                        card.isEmpty() && !creating,
                        appearance,
                        palette.slug,
                    )
                }
                .collect()
        }
        return MobileObservation { job.cancel() }
    }

    fun controller(): UIViewController =
        ComposeUIViewController(
            configure = {
                // Shared imePadding and scroll containers keep focused controls visible.
                // Panning the entire native host also moves fixed headers out of reach.
                onFocusBehavior = OnFocusBehavior.DoNothing
            }
        ) {
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
        store.navigate(primaryTabs.getOrElse(index) { MobileTab.INBOX })
    }

    fun newTask() {
        store.newConversation(store.tab.value == MobileTab.CHATS)
    }

    fun reconnect() = store.retry()

    fun completeSignIn(url: String) = store.completeSignIn(url)

    fun setForeground(active: Boolean) = store.setForeground(active)

    fun adoptFixture(url: String, token: String) = store.action {
        store.core.dispatch(
            Command(adopt_session = AdoptSession(url, token, "Isolated Compose spike"))
        )
        store.agentSelection = com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
    }

    fun close() {
        hostScope.cancel()
        MainScope().launch {
            store.flushDrafts()
            store.close()
            shared.shutdown()
        }
    }
}

internal fun ByteArray.data(): NSData =
    if (isEmpty()) NSData()
    else usePinned { NSData.create(bytes = it.addressOf(0), length = size.convert()) }

internal fun NSData.bytesArray(): ByteArray =
    ByteArray(length.toInt()).also { result ->
        if (result.isNotEmpty()) result.usePinned { memcpy(it.addressOf(0), bytes, length) }
    }

interface MobileNavigationObserver {
    fun changed(index: Int, chromeVisible: Boolean, appearance: String, palette: String)
}

class MobileObservation(private val closeBlock: () -> Unit) {
    fun close() = closeBlock()
}
