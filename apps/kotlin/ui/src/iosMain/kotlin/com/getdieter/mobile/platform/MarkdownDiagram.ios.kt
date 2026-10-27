@file:OptIn(
    kotlinx.cinterop.ExperimentalForeignApi::class,
    androidx.compose.ui.ExperimentalComposeUiApi::class,
)

package com.getdieter.mobile.platform

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitInteropProperties
import androidx.compose.ui.viewinterop.UIKitView
import com.getdieter.core.presentation.MarkdownDiagrams
import kotlinx.cinterop.*
import kotlinx.serialization.json.*
import platform.CoreGraphics.*
import platform.Foundation.*
import platform.UIKit.UIColor
import platform.UIKit.UIScrollViewContentInsetAdjustmentBehavior
import platform.UIKit.UIView
import platform.WebKit.*
import platform.darwin.NSObject

private const val SCHEME = "dieter-markdown"

private class DiagramScheme(val assets: Map<String, ByteArray>) :
    NSObject(), WKURLSchemeHandlerProtocol {
    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, startURLSchemeTask: WKURLSchemeTaskProtocol) {
        val url = startURLSchemeTask.request.URL ?: return
        val normalized =
            url.absoluteString?.replace("$SCHEME://preview/", MarkdownDiagrams.ORIGIN).orEmpty()
        val name = MarkdownDiagrams.asset(normalized)
        val bytes = assets[name]
        if (bytes == null) {
            startURLSchemeTask.didFailWithError(
                NSError.errorWithDomain(NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile, null)
            )
            return
        }
        val mime =
            when (name) {
                "app.js" -> "text/javascript"
                "app.css" -> "text/css"
                else -> "text/html"
            }
        startURLSchemeTask.didReceiveResponse(
            NSURLResponse(url, mime, bytes.size.toLong(), "utf-8")
        )
        startURLSchemeTask.didReceiveData(bytes.data())
        startURLSchemeTask.didFinish()
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, stopURLSchemeTask: WKURLSchemeTaskProtocol) = Unit
}

private class DiagramHost(
    val assets: Map<String, ByteArray>,
    val script: String,
    val result: (Double, String?) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol, WKScriptMessageHandlerProtocol {
    var closed = false
    var loaded = false
    var width = 0.0
    val view: WKWebView
    val container: UIView

    init {
        val configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(this, "diagram")
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
        configuration.setURLSchemeHandler(DiagramScheme(assets), SCHEME)
        view = WKWebView(frame = CGRectZero.readValue(), configuration = configuration)
        view.navigationDelegate = this
        view.opaque = false
        view.backgroundColor = UIColor.clearColor
        // WebKit's scroll/page backing can stay white after the document turns
        // transparent. Clear every native layer so it blends with Compose Mail.
        view.underPageBackgroundColor = UIColor.clearColor
        view.scrollView.backgroundColor = UIColor.clearColor
        view.scrollView.opaque = false
        view.scrollView.scrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior =
            UIScrollViewContentInsetAdjustmentBehavior.UIScrollViewContentInsetAdjustmentNever
        // Compose moves/clips its interop child while scrolling. Keep WebKit's
        // own frame at the local origin so it cannot shift its page viewport
        // to compensate for a partially clipped native frame.
        container =
            object : UIView(frame = CGRectZero.readValue()) {
                override fun layoutSubviews() {
                    super.layoutSubviews()
                    view.setFrame(bounds)
                    val nextWidth = bounds.useContents { size.width }
                    if (nextWidth > 0 && nextWidth != width) {
                        width = nextWidth
                        render()
                    }
                }
            }
        container.opaque = false
        container.backgroundColor = UIColor.clearColor
        container.addSubview(view)
        view.loadRequest(NSURLRequest(NSURL(string = "$SCHEME://preview/index.html")))
    }

    fun render() {
        if (!loaded || closed || width <= 0) return
        view.evaluateJavaScript(
            script +
                ".then(r => window.webkit.messageHandlers.diagram.postMessage(r)).catch(() => window.webkit.messageHandlers.diagram.postMessage('{}'));void 0",
            null,
        )
    }

    override fun userContentController(
        userContentController: WKUserContentController,
        didReceiveScriptMessage: WKScriptMessage,
    ) {
        if (!closed)
            runCatching {
                val json =
                    Json.parseToJsonElement(didReceiveScriptMessage.body as String).jsonObject
                if (json["stale"]?.jsonPrimitive?.boolean != true)
                    result(
                        json["height"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                        json["error"]?.jsonPrimitive?.contentOrNull,
                    )
            }
                .onFailure { result(0.0, "The diagram could not render.") }
    }

    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
        loaded = true
        render()
    }

    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) {
        val initial =
            !loaded &&
                decidePolicyForNavigationAction.request.URL?.absoluteString ==
                    "$SCHEME://preview/index.html"
        decisionHandler(
            if (initial) WKNavigationActionPolicy.WKNavigationActionPolicyAllow
            else WKNavigationActionPolicy.WKNavigationActionPolicyCancel
        )
    }

    override fun webViewWebContentProcessDidTerminate(webView: WKWebView) {
        result(0.0, "The offline diagram renderer stopped.")
    }

    fun close() {
        closed = true
        view.evaluateJavaScript("window.dieterMarkdown?.dispose()", null)
        view.stopLoading()
        view.navigationDelegate = null
        view.configuration.userContentController.removeScriptMessageHandlerForName("diagram")
    }
}

@Composable
internal actual fun NativeMarkdownDiagram(
    assets: Map<String, ByteArray>,
    script: String,
    modifier: Modifier,
    onResult: (Double, String?) -> Unit,
) {
    val callback by rememberUpdatedState(onResult)
    val host = remember { DiagramHost(assets, script) { height, error -> callback(height, error) } }
    UIKitView(
        factory = { host.container },
        // Default interop punches a hole through Compose, so transparent pixels
        // show UIKit's root background instead of the Mail message surface.
        properties = UIKitInteropProperties(placedAsOverlay = true),
        modifier = modifier,
    )
    DisposableEffect(host) { onDispose { host.close() } }
}
