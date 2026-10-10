package com.dbpprt.dieter.core.files

import com.dbpprt.dieter.core.identity.Urls

/**
 * Sandboxed previews of workspace HTML, such as Claude Design's standalone exports. A preview loads
 * its document from the private `dieter-preview://workspace/` origin, so relative references
 * resolve against the document's folder and every request returns to the client. The client serves
 * only workspace files it reads through the daemon, each with [CONTENT_SECURITY_POLICY], and fails
 * every other request: a preview never reaches the network, so it cannot send workspace files
 * anywhere.
 */
object HtmlPreview {
    const val SCHEME = "dieter-preview"
    private const val ORIGIN = "$SCHEME://workspace/"

    /** Requests one preview may serve, the document included; later ones fail. */
    const val MAX_RESOURCES = 128

    /**
     * No network, frames, form posts, or plugins; inline code, `data:`, and `blob:` stay usable.
     */
    const val CONTENT_SECURITY_POLICY =
        "default-src $SCHEME: data: blob:; " +
            "script-src $SCHEME: 'unsafe-inline' 'unsafe-eval' data: blob:; " +
            "style-src $SCHEME: 'unsafe-inline' data:; " +
            "img-src $SCHEME: data: blob:; font-src $SCHEME: data:; media-src $SCHEME: data: blob:; " +
            "connect-src $SCHEME: data: blob:; frame-src 'none'; object-src 'none'; " +
            "form-action 'none'; base-uri $SCHEME:"

    /** The URL a preview loads [documentPath] (workspace-relative) from. */
    fun documentUrl(documentPath: String): String =
        ORIGIN +
            documentPath.split('/').filter { it.isNotEmpty() }.joinToString("/") { Urls.encode(it) }

    /**
     * The workspace-relative file a preview request for [url] reads; null for another origin, a
     * path that leaves the workspace, or `.git`.
     */
    fun resource(url: String): String? {
        if (!url.startsWith(ORIGIN, ignoreCase = true)) return null
        val path =
            Urls.decodePath(url.substring(ORIGIN.length).substringBefore('#').substringBefore('?'))
        if (path.isEmpty() || '\\' in path) return null
        return FilePaths.normalize(path).getOrNull()?.takeIf { it.isNotEmpty() }
    }

    /**
     * The media type to serve [path] with; [reported] is the daemon's, used for other extensions.
     */
    fun mimeType(path: String, reported: String): String =
        when (path.substringAfterLast('/').substringAfterLast('.', "").lowercase()) {
            "html",
            "htm" -> "text/html"
            "css" -> "text/css"
            "js",
            "mjs",
            "cjs" -> "text/javascript"
            "json",
            "map" -> "application/json"
            "svg" -> "image/svg+xml"
            "png" -> "image/png"
            "jpg",
            "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "avif" -> "image/avif"
            "ico" -> "image/x-icon"
            "woff" -> "font/woff"
            "woff2" -> "font/woff2"
            "ttf" -> "font/ttf"
            "otf" -> "font/otf"
            "mp4" -> "video/mp4"
            "webm" -> "video/webm"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "txt" -> "text/plain"
            else ->
                reported.substringBefore(';').trim().lowercase().ifEmpty {
                    "application/octet-stream"
                }
        }
}
