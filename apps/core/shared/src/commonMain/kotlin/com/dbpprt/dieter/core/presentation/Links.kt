package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.core.identity.Urls

/** Where a link in a conversation leads. */
sealed interface ContentLink {
    /** A workspace file, relative to the workspace root, optionally at a line range. */
    data class File(val path: String, val line: Int? = null, val endLine: Int? = null) : ContentLink
    data class Web(val url: String) : ContentLink
}

enum class LinkError { INVALID_WEB_URL, UNSUPPORTED_FILE_HOST, UNSUPPORTED_SCHEME, INVALID_LINE, INVALID_LINK, INVALID_WORKSPACE, OUTSIDE_WORKSPACE }

class LinkException(val error: LinkError) : IllegalArgumentException(error.name)

/**
 * Resolves links authored in agent output. Files must stay inside the
 * conversation's workspace; nothing is resolved against the client's disk.
 * Ported from the macOS `ConversationContentLink`.
 */
object ContentLinks {
    private val lineSuffix = Regex(":([0-9]+)(?::([0-9]+))?$")
    private val lineFragment = Regex("^L([0-9]+)(?:-L?([0-9]+))?$")
    private val scheme = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    fun resolve(url: String, workspaceRoot: String?, relativeTo: String? = null): ContentLink {
        val match = scheme.find(url)
        val schemeName = match?.groupValues?.get(1)?.lowercase()
        when {
            schemeName == "http" || schemeName == "https" -> {
                val rest = url.substringAfter("://", "")
                val host = rest.substringBefore('/').substringBefore('?').substringBefore('#')
                if (!url.contains("://") || host.isEmpty()) throw LinkException(LinkError.INVALID_WEB_URL)
                return ContentLink.Web(url)
            }
            schemeName == "file" -> {
                var rest = url.substringAfter(':')
                if (rest.startsWith("//")) {
                    val host = rest.drop(2).substringBefore('/')
                    if (host.isNotEmpty() && !host.equals("localhost", ignoreCase = true)) throw LinkException(LinkError.UNSUPPORTED_FILE_HOST)
                    rest = rest.drop(2 + host.length)
                }
                if (!rest.startsWith("/")) throw LinkException(LinkError.INVALID_LINK)
                return file(rest, workspaceRoot, relativeTo)
            }
            schemeName != null && !(schemeName.contains('.') && !url.contains("://") && lineSuffix.containsMatchIn(url.substringBefore('#'))) -> {
                if (url.startsWith("//")) throw LinkException(LinkError.UNSUPPORTED_FILE_HOST)
                throw LinkException(LinkError.UNSUPPORTED_SCHEME)
            }
            url.startsWith("//") -> throw LinkException(LinkError.UNSUPPORTED_FILE_HOST)
        }
        return file(url, workspaceRoot, relativeTo)
    }

    private fun file(raw: String, workspaceRoot: String?, relativeTo: String?): ContentLink.File {
        val root = workspaceRoot?.takeIf { it.startsWith("/") } ?: throw LinkException(LinkError.INVALID_WORKSPACE)
        val fragment = raw.substringAfter('#', "")
        var path = Urls.decodePath(raw.substringBefore('#').substringBefore('?'))
        var line: Int? = null
        var endLine: Int? = null
        lineSuffix.find(path)?.let { suffix ->
            path = path.dropLast(suffix.value.length)
            line = suffix.groupValues[1].toIntOrNull()
        }
        lineFragment.find(fragment)?.let { match ->
            line = match.groupValues[1].toIntOrNull()
            endLine = match.groupValues[2].takeIf { it.isNotEmpty() }?.toIntOrNull()
        }
        line?.let { if (it <= 0) throw LinkException(LinkError.INVALID_LINE) }
        endLine?.let { end -> if (end < (line ?: 0)) throw LinkException(LinkError.INVALID_LINE) }
        if (path.any { it == '\\' || it.code < 0x20 || it.code == 0x7f }) throw LinkException(LinkError.INVALID_LINK)
        val rootParts = components(root) ?: throw LinkException(LinkError.INVALID_WORKSPACE)
        val base = when {
            path.isEmpty() -> relativeTo ?: throw LinkException(LinkError.INVALID_LINK)
            path.startsWith("/") -> path
            else -> {
                val directory = relativeTo?.let { if (it.startsWith("/")) it else "$root/$it" }?.substringBeforeLast('/') ?: root
                "$directory/$path"
            }
        }
        val absolute = components(if (base.startsWith("/")) base else "$root/$base") ?: throw LinkException(LinkError.OUTSIDE_WORKSPACE)
        if (absolute.size <= rootParts.size || absolute.take(rootParts.size) != rootParts) throw LinkException(LinkError.OUTSIDE_WORKSPACE)
        return ContentLink.File(absolute.drop(rootParts.size).joinToString("/"), line, endLine)
    }

    /** Normalized absolute components, or null when `..` escapes the filesystem root. */
    private fun components(path: String): List<String>? {
        val parts = mutableListOf<String>()
        for (part in path.split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.lastIndex)
                else -> parts += part
            }
        }
        return parts
    }
}

/** Image files an agent references inside its workspace, shown inline. */
object WorkspaceImages {
    private val extensions = setOf("apng", "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp")

    /** The workspace-relative path of an image link, or null when it is not a workspace image. */
    fun path(destination: String, workspaceRoot: String? = null): String? {
        val raw = destination.trim().removeSurrounding("<", ">")
        if (Regex("^[A-Za-z][A-Za-z0-9+.-]*://").containsMatchIn(raw) && !raw.startsWith("file://")) return null
        var location = raw
        if (raw.startsWith("file://")) {
            // Only this machine's files: an empty host or localhost.
            val host = raw.removePrefix("file://").substringBefore('/')
            if (host.isNotEmpty() && !host.equals("localhost", ignoreCase = true)) return null
            location = raw.removePrefix("file://").removePrefix(host)
        }
        val decoded = Urls.decodePath(location.substringBefore('#').substringBefore('?'))
        if (decoded.isEmpty() || decoded.any { it == '\\' || it.code < 0x20 }) return null
        if (decoded.substringAfterLast('.', "").lowercase() !in extensions) return null
        val parts = mutableListOf<String>()
        if (!decoded.startsWith("/")) {
            for (part in decoded.split('/')) when (part) {
                "", "." -> Unit
                ".." -> return null
                else -> parts += part
            }
            return parts.joinToString("/").ifEmpty { null }
        }
        val root = workspaceRoot?.trimEnd('/')?.takeIf { it.startsWith("/") } ?: return null
        val relative = decoded.removePrefix("$root/").takeIf { decoded.startsWith("$root/") } ?: return null
        return path(relative, null)
    }
}

/** Bare development addresses (`localhost:3000/path`) in prose become web links. */
object DetectedLinks {
    private val address = Regex("(?i)(?<![a-z0-9_./@:\\-])(?:localhost|\\[::1\\]|(?:[0-9]{1,3}\\.){3}[0-9]{1,3}):[0-9]{1,5}(?![a-z0-9_])(?:[/?#][^\\s<>\"`]+)?")

    data class Match(val range: IntRange, val url: String)

    fun find(text: String): List<Match> = address.findAll(text).mapNotNull { match ->
        var value = match.value
        while (value.isNotEmpty() && value.last() in ".,;!") value = value.dropLast(1)
        for ((open, close) in listOf('(' to ')', '[' to ']', '{' to '}')) {
            while (value.endsWith(close) && value.count { it == close } > value.count { it == open }) value = value.dropLast(1)
        }
        val host = value.substringBefore('/').substringBefore('?').substringBefore('#')
        val port = host.substringAfterLast(':').toIntOrNull() ?: return@mapNotNull null
        if (port !in 1..65535) return@mapNotNull null
        val octets = host.substringBeforeLast(':').split('.')
        if (octets.size == 4 && octets.any { (it.toIntOrNull() ?: 256) > 255 }) return@mapNotNull null
        Match(match.range.first until match.range.first + value.length, "http://$value")
    }.toList()
}

enum class DeliveryState { LOCAL, ACCEPTED, QUEUED, SYNCED, FAILED }

object Delivery {
    /** A user message's delivery: failed, then queued, then synced (no longer pending), then accepted, else local. */
    fun state(messageId: String, pending: Set<String>, accepted: Set<String>, failed: Set<String>, queued: Set<String> = emptySet()): DeliveryState = when {
        messageId in failed -> DeliveryState.FAILED
        messageId in queued -> DeliveryState.QUEUED
        messageId !in pending -> DeliveryState.SYNCED
        messageId in accepted -> DeliveryState.ACCEPTED
        else -> DeliveryState.LOCAL
    }
}
