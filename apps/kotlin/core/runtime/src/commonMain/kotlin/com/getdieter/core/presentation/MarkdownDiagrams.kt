package com.getdieter.core.presentation

/** Supported offline graphics. The bundled renderer owns validation, limits and resource denial. */
object MarkdownDiagrams {
    fun kind(info: String): String? =
        when (info.trim().takeWhile { !it.isWhitespace() }.lowercase()) {
            "mermaid" -> "mermaid"
            "vega-lite",
            "vegalite" -> "vega-lite"
            "vega" -> "vega"
            else -> null
        }

    const val ORIGIN = "https://markdown.dieter.invalid/"

    /** Only these packaged assets can ever be served to a diagram view. */
    fun asset(url: String): String? =
        when (url) {
            "${ORIGIN}index.html" -> "index.html"
            "${ORIGIN}app.js" -> "app.js"
            "${ORIGIN}app.css" -> "app.css"
            else -> null
        }
}
