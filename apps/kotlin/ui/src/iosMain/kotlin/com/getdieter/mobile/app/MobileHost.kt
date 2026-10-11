@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package com.getdieter.mobile.app

import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.*
import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.window.ComposeUIViewController
import com.getdieter.apple.DieterShared
import com.getdieter.apple.SharedObserver
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import kotlinx.cinterop.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import platform.Foundation.*
import platform.UIKit.UIApplication
import platform.UIKit.UIViewController

/** A route as the native shell sees it. The shell keys view controllers by [key]. */
class MobileRouteHandle internal constructor(internal val route: MobileRoute) {
    val key: String = route.key
    val immersive: Boolean = route.immersive
}

/** One immutable navigation state for the UIKit tab and navigation controllers. */
class NativeNavigation(
    val tab: Int,
    val stacks: List<List<MobileRouteHandle>>,
    val modal: MobileRouteHandle?,
    val signedIn: Boolean,
    val appearance: String,
    val attention: Int,
    /** ARGB accent for native controls; 0 means the label color (monochrome). */
    val accent: Long,
)

interface MobileNavigationObserver {
    fun changed(navigation: NativeNavigation)
}

class MobileObservation(private val closeBlock: () -> Unit) {
    fun close() = closeBlock()
}

/** One shared store; each route is its own Compose view controller under native chrome. */
class MobileHost(private val shared: DieterShared, private val nativeViews: MobileNativeViews) {
    internal val store =
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
    private val openUrl: (String) -> Unit = { url ->
        NSURL.URLWithString(url)?.let {
            UIApplication.sharedApplication.openURL(
                it,
                options = emptyMap<Any?, Any>(),
                completionHandler = null,
            )
        }
    }

    init {
        AppleNativeViews.factory = nativeViews
        hostScope.launch {
            store.session.signInUrl.collect { url ->
                if (url.isNotEmpty()) {
                    openUrl(url)
                    store.session.signInUrl.value = ""
                }
            }
        }
        hostScope.launch {
            store.error.collect { message ->
                if (message.isNotEmpty()) {
                    nativeViews.showToast(message)
                    delay(400)
                    if (store.error.value == message) store.error.value = ""
                }
            }
        }
    }

    fun observeNavigation(observer: MobileNavigationObserver): MobileObservation {
        val job = hostScope.launch {
            combine(
                    store.routes,
                    store.session.slice,
                    store.workspace.slice,
                    combine(store.theme.appearance, store.theme.palette, ::Pair),
                    store.workspace.activity,
                ) { _, _, _, _, _ ->
                    navigation()
                }
                .collect { observer.changed(it) }
        }
        return MobileObservation { job.cancel() }
    }

    /** The current navigation, read synchronously once UIKit has reported a finished transition. */
    fun navigation(): NativeNavigation {
        val routes = store.routes.value
        val palette = store.theme.palette.value
        return NativeNavigation(
            MobileTab.entries.indexOf(routes.tab),
            MobileTab.entries.map { tab -> routes.stacks.getValue(tab).map(::MobileRouteHandle) },
            routes.modal?.let(::MobileRouteHandle),
            !(store.session.slice.value.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED &&
                !store.workspace.slice.value.loaded),
            store.theme.appearance.value,
            store.workspace.activity.value.summary?.attention ?: 0,
            if (palette == com.getdieter.mobile.settings.DieterPalette.MONOCHROME) 0L
            else palette.tokens.shellEnd,
        )
    }

    /** A Compose screen for one route. [chrome] receives its navigation item contents. */
    fun controller(route: MobileRouteHandle, chrome: NativeChromeSink): UIViewController {
        var created: UIViewController? = null
        val host = AppleChromeHost(chrome)
        val overlays = AppleOverlays(nativeViews, store) { created?.view }
        val controller =
            ComposeUIViewController(configure = { onFocusBehavior = OnFocusBehavior.DoNothing }) {
                AppleRoot(store, host, overlays) { RouteContent(store, route.route, openUrl) }
            }
        created = controller
        return controller
    }

    fun signInController(): UIViewController {
        var created: UIViewController? = null
        val overlays = AppleOverlays(nativeViews, store) { created?.view }
        val controller =
            ComposeUIViewController(configure = { onFocusBehavior = OnFocusBehavior.DoNothing }) {
                AppleRoot(store, null, overlays) { SignInContent(store) }
            }
        created = controller
        return controller
    }

    /** The iPad detail column's empty state for a tab, in Apple title case. */
    fun emptyDetail(tab: Int): NativeEmptyDetail {
        val empty = MobileTab.entries.getOrElse(tab) { MobileTab.INBOX }.emptyDetail
        val title =
            empty.title.split(" ").joinToString(" ") { word ->
                word.replaceFirstChar(Char::uppercaseChar)
            }
        return NativeEmptyDetail(empty.glyph.symbol, title, empty.message)
    }

    fun selectTab(index: Int) =
        store.selectTab(MobileTab.entries.getOrElse(index) { MobileTab.INBOX })

    /** A native back gesture or button left [depth] routes on the tab's stack. */
    fun popTo(tab: Int, depth: Int) =
        store.popTo(MobileTab.entries.getOrElse(tab) { MobileTab.INBOX }, depth)

    fun dismissModal() = store.dismiss()

    /**
     * Items the share extension handed over: [message] is an encoded UiMessage of the files,
     * [destination] "new-task", "task" or "chat", and [problem] what could not be read.
     */
    fun share(message: NSData, destination: String, problem: String) =
        store.sharing.receive(
            SharedItems(
                "",
                com.getdieter.api.v1.UiMessage.ADAPTER.decode(message.bytesArray()).parts,
                when (destination) {
                    "task" -> ShareDestination.TASK
                    "chat" -> ShareDestination.CHAT
                    else -> ShareDestination.NEW_TASK
                },
                problem,
            )
        )

    fun newTask() = store.newConversation(store.routes.value.tab == MobileTab.CHATS)

    fun reconnect() = store.session.retry()

    fun completeSignIn(url: String) = store.session.completeSignIn(url)

    fun setForeground(active: Boolean) = store.setForeground(active)

    fun adoptFixture(url: String, token: String) = store.action {
        store.core.dispatch(Command(adopt_session = AdoptSession(url, token, "Isolated journey")))
        store.creation.agentSelection = com.getdieter.api.v1.HarnessSelection("mock", "mock", "low")
    }

    /** Debug builds replay a navigation script for screenshots. */
    fun runDebugScript(script: String) {
        store.debugScript(script)
    }

    fun close() {
        hostScope.cancel()
        MainScope().launch {
            store.conversation.flushDrafts()
            store.close()
            shared.shutdown()
        }
    }
}

/** Theme and native bridges for every Compose view controller. */
@Composable
internal fun AppleRoot(
    store: MobileStore,
    chrome: ChromeHost?,
    overlays: NativeOverlays,
    content: @Composable () -> Unit,
) {
    MobileTheme(store, apple = true) {
        CompositionLocalProvider(
            LocalChromeHost provides chrome,
            LocalNativeOverlays provides overlays,
            LocalMobileStore provides store,
            LocalContentColor provides palette.label,
            LocalTextStyle provides type.body,
        ) {
            content()
        }
    }
}

class NativeEmptyDetail(val symbol: String, val title: String, val message: String)
