@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.getdieter.mobile.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.window.ComposeUIViewController
import com.getdieter.mobile.design.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import platform.UIKit.*

/** Receives a screen's bar contents; implemented by the native navigation item. */
interface NativeChromeSink {
    fun apply(chrome: NativeChrome)

    fun setTitleCollapsed(collapsed: Boolean)
}

class NativeChrome(
    val title: String,
    val subtitle: String,
    val large: Boolean,
    val actions: List<NativeAction>,
    val primary: NativeAction?,
    val confirm: NativeAction?,
    val cancel: NativeAction?,
)

/** A bar button or menu element. [perform] always runs the screen's latest handler. */
class NativeAction
internal constructor(
    val identifier: String,
    val title: String,
    val symbol: String,
    val subtitle: String,
    val enabled: Boolean,
    val destructive: Boolean,
    val checked: Boolean,
    val sections: List<NativeMenuSection>,
    private val run: () -> Unit,
) {
    fun perform() = run()
}

class NativeMenuSection(
    val title: String,
    val symbol: String,
    val inline: Boolean,
    val actions: List<NativeAction>,
)

/** Publishes chrome when its structure changes; handlers stay current on every recomposition. */
internal class AppleChromeHost(private val sink: NativeChromeSink) : ChromeHost {
    private val handlers = mutableMapOf<String, () -> Unit>()
    private var signature: String? = null
    private var collapsed: Boolean? = null

    override fun publish(chrome: ScreenChrome) {
        handlers.clear()
        fun register(action: ChromeAction) {
            handlers[action.id] = action.onClick
            action.menu.forEach { section -> section.actions.forEach(::register) }
        }
        (chrome.actions + listOfNotNull(chrome.primary, chrome.confirm, chrome.cancel)).forEach(
            ::register
        )
        val next = chrome.signature
        if (next == signature) return
        signature = next
        sink.apply(
            NativeChrome(
                chrome.title,
                chrome.subtitle,
                chrome.large,
                chrome.actions.map(::native),
                chrome.primary?.let(::native),
                chrome.confirm?.let(::native),
                chrome.cancel?.let(::native),
            )
        )
    }

    override fun titleCollapsed(collapsed: Boolean) {
        if (this.collapsed == collapsed) return
        this.collapsed = collapsed
        sink.setTitleCollapsed(collapsed)
    }

    private fun native(action: ChromeAction): NativeAction =
        NativeAction(
            action.id,
            action.title,
            action.glyph?.symbol.orEmpty(),
            action.subtitle.ifEmpty { action.value },
            action.enabled,
            action.destructive,
            action.checked,
            action.menu.map { section ->
                NativeMenuSection(
                    section.title,
                    section.glyph?.symbol.orEmpty(),
                    section.inline,
                    section.actions.map(::native),
                )
            },
        ) {
            handlers[action.id]?.invoke()
        }
}

/** One-shot menu elements run the handler they were built with. */
internal fun MenuSection.toNative(): NativeMenuSection =
    NativeMenuSection(title, glyph?.symbol.orEmpty(), inline, actions.map { it.toNative() })

internal fun ChromeAction.toNative(): NativeAction =
    NativeAction(
        id,
        title,
        glyph?.symbol.orEmpty(),
        subtitle.ifEmpty { value },
        enabled,
        destructive,
        checked,
        menu.map { it.toNative() },
        onClick,
    )

/** UIKit presentations for one Compose view controller. */
internal class AppleOverlays(
    private val views: MobileNativeViews,
    private val store: MobileStore,
    private val anchor: () -> UIView?,
) : NativeOverlays {
    override fun showMenu(
        sections: List<MenuSection>,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        onDismiss: () -> Unit,
    ) {
        val view = anchor()
        if (view != null) views.showMenu(sections.map { it.toNative() }, view, x, y, width, height)
        onDismiss()
    }

    override fun confirm(
        title: String,
        message: String,
        confirm: String,
        destructive: Boolean,
        onConfirm: () -> Unit,
        onCancel: () -> Unit,
    ) {
        val view = anchor() ?: return onCancel()
        views.confirm(
            title,
            message,
            confirm,
            destructive,
            view,
            object : NativeChoice {
                override fun chose(confirmed: Boolean) = if (confirmed) onConfirm() else onCancel()
            },
        )
    }

    override fun prompt(
        title: String,
        message: String,
        value: String,
        placeholder: String,
        confirm: String,
        onConfirm: (String) -> Unit,
        onCancel: () -> Unit,
    ) {
        val view = anchor() ?: return onCancel()
        views.prompt(
            title,
            message,
            value,
            placeholder,
            confirm,
            view,
            object : NativeText {
                override fun entered(text: String?) =
                    if (text != null) onConfirm(text) else onCancel()
            },
        )
    }

    override fun presentSheet(
        title: String,
        size: SheetSize,
        chrome: State<ScreenChrome>,
        content: State<@Composable () -> Unit>,
        onDismiss: () -> Unit,
    ): AutoCloseable {
        val view = anchor() ?: return AutoCloseable {}
        var host: AppleChromeHost? = null
        var created: UIViewController? = null
        val overlays = AppleOverlays(views, store) { created?.view }
        val controller =
            ComposeUIViewController(configure = { onFocusBehavior = OnFocusBehavior.DoNothing }) {
                AppleRoot(store, null, overlays) {
                    val current = chrome.value
                    SideEffect {
                        host?.publish(
                            ScreenChrome(
                                current.title,
                                current.subtitle,
                                confirm = current.confirm,
                                cancel =
                                    ChromeAction(
                                        "close-sheet",
                                        "Close",
                                        Glyph.CLOSE,
                                        onClick = onDismiss,
                                    ),
                            )
                        )
                    }
                    Box(
                        Modifier.fillMaxSize()
                            .background(palette.background)
                            .windowInsetsPadding(
                                WindowInsets.safeDrawing.only(
                                    WindowInsetsSides.Top + WindowInsetsSides.Horizontal
                                )
                            )
                            .imePadding()
                    ) {
                        content.value()
                    }
                }
            }
        created = controller
        val sheet =
            views.presentSheet(
                controller,
                size == SheetSize.MEDIUM,
                view,
                object : NativeChoice {
                    override fun chose(confirmed: Boolean) = onDismiss()
                },
            )
        val chromeHost = AppleChromeHost(sheet.chrome)
        host = chromeHost
        val current = chrome.value
        chromeHost.publish(
            ScreenChrome(
                current.title,
                current.subtitle,
                confirm = current.confirm,
                cancel = ChromeAction("close-sheet", "Close", Glyph.CLOSE, onClick = onDismiss),
            )
        )
        return AutoCloseable { sheet.close() }
    }
}
