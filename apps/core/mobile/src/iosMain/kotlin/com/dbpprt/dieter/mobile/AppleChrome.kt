@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.ColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.uikit.OnFocusBehavior
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.window.ComposeUIViewController
import kotlinx.cinterop.useContents
import platform.CoreGraphics.CGPointMake
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
            action.subtitle,
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
        subtitle,
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

// ---------------------------------------------------------------------------------------------
// Platform actuals
// ---------------------------------------------------------------------------------------------

@Composable internal actual fun platformDynamicScheme(dark: Boolean): ColorScheme? = null

internal actual val platformSupportsDynamicColor: Boolean
    get() = false

@Composable internal actual fun SystemBackHandler(enabled: Boolean, onBack: () -> Unit) = Unit

private val monospace: androidx.compose.ui.text.font.FontFamily by lazy {
    val typeface =
        listOf("SFMono-Regular", ".AppleSystemUIFontMonospaced", "Menlo-Regular")
            .firstNotNullOfOrNull { name ->
                org.jetbrains.skia.FontMgr.default.matchFamilyStyle(
                    name,
                    org.jetbrains.skia.FontStyle.NORMAL,
                )
            }
    if (typeface == null) androidx.compose.ui.text.font.FontFamily.Monospace
    else
        androidx.compose.ui.text.font.FontFamily(
            androidx.compose.ui.text.platform.Typeface(typeface)
        )
}

internal actual fun platformMonospace(): androidx.compose.ui.text.font.FontFamily = monospace

@Composable
internal actual fun platformSymbolPainter(symbol: String, size: Dp, weight: GlyphWeight): Painter? {
    val scale = LocalDensity.current.density
    return remember(symbol, size, weight, scale) {
        SymbolPainters.get(symbol, size.value, weight, scale)
    }
}

/** Renders SF Symbols once per size and weight; Compose tints them like any icon. */
internal object SymbolPainters {
    private val cache = mutableMapOf<String, Painter?>()

    fun get(symbol: String, size: Float, weight: GlyphWeight, scale: Float): Painter? =
        cache.getOrPut("$symbol|$size|$weight|$scale") { render(symbol, size, weight, scale) }

    private fun render(symbol: String, size: Float, weight: GlyphWeight, scale: Float): Painter? {
        val uiWeight =
            when (weight) {
                GlyphWeight.LIGHT -> UIImageSymbolWeightLight
                GlyphWeight.REGULAR -> UIImageSymbolWeightRegular
                GlyphWeight.MEDIUM -> UIImageSymbolWeightMedium
                GlyphWeight.SEMIBOLD -> UIImageSymbolWeightSemibold
                GlyphWeight.BOLD -> UIImageSymbolWeightBold
            }
        val configuration =
            UIImageSymbolConfiguration.configurationWithPointSize((size * .8f).toDouble(), uiWeight)
        val image = UIImage.systemImageNamed(symbol, configuration) ?: return null
        val tinted =
            image.imageWithTintColor(
                UIColor.blackColor,
                UIImageRenderingMode.UIImageRenderingModeAlwaysOriginal,
            )
        val format = UIGraphicsImageRendererFormat.preferredFormat()
        format.scale = scale.toDouble()
        format.opaque = false
        val renderer = UIGraphicsImageRenderer(tinted.size, format)
        val rendered = renderer.imageWithActions { tinted.drawAtPoint(CGPointMake(0.0, 0.0)) }
        val png = UIImagePNGRepresentation(rendered) ?: return null
        val skia = org.jetbrains.skia.Image.makeFromEncoded(png.bytesArray())
        val width = tinted.size.useContents { width }
        if (width <= 0.0) return null
        return BitmapPainter(skia.toComposeImageBitmap())
    }
}
