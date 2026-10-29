package com.getdieter.mobile.platform

import android.annotation.SuppressLint
import android.webkit.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.viewinterop.AndroidView
import com.getdieter.core.presentation.MarkdownDiagrams
import com.getdieter.mobile.design.palette
import java.io.ByteArrayInputStream
import kotlinx.serialization.json.*

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal actual fun NativeMarkdownDiagram(
    assets: Map<String, ByteArray>,
    script: String,
    modifier: Modifier,
    onResult: (Double, String?) -> Unit,
) {
    val callback by rememberUpdatedState(onResult)
    val dark = palette.dark
    val background = palette.background.toArgb()
    val page = remember(assets, dark) { assets["index.html"]?.let { diagramPage(it, dark) } }
    var view by remember { mutableStateOf<WebView?>(null) }
    AndroidView(
        modifier = modifier,
        factory = { context ->
            object : WebView(context) {
                    var loaded = false
                    var closed = false

                    fun render() {
                        if (!loaded || closed || width <= 0) return
                        evaluateJavascript(
                            script +
                                ".then(r => window.dieterDiagram.result(r)).catch(() => window.dieterDiagram.result('{}'));void 0",
                            null,
                        )
                    }

                    @JavascriptInterface
                    fun result(encoded: String) {
                        post {
                            if (!closed)
                                runCatching {
                                    val json = Json.parseToJsonElement(encoded).jsonObject
                                    if (json["stale"]?.jsonPrimitive?.boolean == true)
                                        return@runCatching
                                    callback(
                                        json["height"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                                        json["error"]?.jsonPrimitive?.contentOrNull,
                                    )
                                }
                                    .onFailure { callback(0.0, "The diagram could not render.") }
                        }
                    }

                    fun updateRasterPolicy() {
                        // Keep visible-size charts ready when LazyColumn moves them
                        // offscreen. Avoid allocating tiles for oversized diagrams.
                        settings.offscreenPreRaster =
                            width > 0 &&
                                height > 0 &&
                                width <= rootView.width &&
                                height <= rootView.height
                    }

                    override fun onAttachedToWindow() {
                        super.onAttachedToWindow()
                        updateRasterPolicy()
                    }

                    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
                        super.onSizeChanged(w, h, oldw, oldh)
                        updateRasterPolicy()
                        if (w != oldw) post { render() }
                    }

                    override fun destroy() {
                        closed = true
                        removeJavascriptInterface("dieterDiagram")
                        super.destroy()
                    }
                }
                .apply {
                    // Chromium can clear hardware tiles while scrolling. Its
                    // native backing must match the reader, including before SVG
                    // readiness; the SVG itself keeps its authored transparency.
                    setBackgroundColor(background)
                    settings.javaScriptEnabled = true
                    addJavascriptInterface(this, "dieterDiagram")
                    settings.allowFileAccess = false
                    settings.allowContentAccess = false
                    settings.domStorageEnabled = false
                    settings.databaseEnabled = false
                    settings.setGeolocationEnabled(false)
                    settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    settings.blockNetworkLoads = true
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    webViewClient =
                        object : WebViewClient() {
                            override fun shouldInterceptRequest(
                                v: WebView,
                                request: WebResourceRequest,
                            ): WebResourceResponse {
                                val name = MarkdownDiagrams.asset(request.url.toString())
                                val data = if (name == "index.html") page else assets[name]
                                val mime =
                                    when (name) {
                                        "app.js" -> "text/javascript"
                                        "app.css" -> "text/css"
                                        else -> "text/html"
                                    }
                                return WebResourceResponse(
                                    mime,
                                    "utf-8",
                                    if (data == null) 403 else 200,
                                    if (data == null) "Blocked" else "OK",
                                    mapOf("X-Content-Type-Options" to "nosniff"),
                                    ByteArrayInputStream(data ?: byteArrayOf()),
                                )
                            }

                            override fun shouldOverrideUrlLoading(
                                v: WebView,
                                request: WebResourceRequest,
                            ) = true

                            override fun onPageFinished(v: WebView, url: String) {
                                loaded = true
                                render()
                            }

                            override fun onRenderProcessGone(
                                v: WebView,
                                detail: RenderProcessGoneDetail,
                            ): Boolean {
                                callback(0.0, "The offline diagram renderer stopped.")
                                return true
                            }
                        }
                    view = this
                    loadUrl(MarkdownDiagrams.ORIGIN + "index.html")
                }
        },
        update = { it.setBackgroundColor(background) },
    )
    DisposableEffect(Unit) {
        onDispose {
            view?.apply {
                stopLoading()
                evaluateJavascript("window.dieterMarkdown?.dispose()", null)
                removeAllViews()
                destroy()
            }
            view = null
        }
    }
}
