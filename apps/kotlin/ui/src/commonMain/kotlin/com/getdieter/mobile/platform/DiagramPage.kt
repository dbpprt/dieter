package com.getdieter.mobile.platform

/** Diagram-only styling must precede the first paint, before the bundle can render its SVG. */
internal fun diagramPage(index: ByteArray, dark: Boolean): ByteArray {
    val theme = if (dark) "dark" else "light"
    return index
        .decodeToString()
        .replaceFirst(
            Regex("<html\\b[^>]*>"),
            """<html lang="en" data-theme="$theme" data-surface="diagram" style="background:transparent;color-scheme:normal">""",
        )
        .replaceFirst("<body>", """<body style="margin:0;background:transparent">""")
        .replaceFirst("""id="preview"""", """id="preview" data-mode="diagram"""")
        .encodeToByteArray()
}
