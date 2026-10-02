package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.core.identity.Urls

/** Where a link in a conversation leads. */
sealed interface ContentLink {
    /** A workspace file, relative to the workspace root, optionally at a line range. */
    data class File(val path: String, val line: Int? = null, val endLine: Int? = null) : ContentLink
    data class Web(val url: String) : ContentLink
}

enum class LinkError { INVALID_WEB_URL, UNSUPPORTED_FILE_HOST, UNSUPPORTED_SCHEME, INVALID_LINE, INVALID_LINK, INVALID_WORKSPACE, OUTSIDE_WORKSPACE }

/** Why a link cannot be opened, worded for people; [scheme] is an unsupported scheme as written. */
class LinkException(val error: LinkError, val scheme: String = "") : IllegalArgumentException(ContentLinks.message(error, scheme))

/**
 * Resolves links authored in agent output. Files must stay inside the
 * conversation's workspace; nothing is resolved against the client's disk,
 * and the owning daemon still checks containment and symlinks itself.
 *
 * A `:line[:column]` suffix is read before percent-decoding, so an encoded
 * `%3A12` stays part of the file name. A `#L12` or `#L12-L14` fragment wins
 * over the suffix. A relative path may not climb above the workspace root at
 * any step, and a fragment-only link (`#L3`) refers to [resolve]'s
 * `relativeTo` document.
 */
object ContentLinks {
    private val lineSuffix = Regex(":([0-9]+)(?::([0-9]+))?$")
    private val lineFragment = Regex("^L([0-9]+)(?:-L?([0-9]+))?$")
    private val scheme = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

    fun message(error: LinkError, scheme: String = ""): String = when (error) {
        LinkError.INVALID_LINK -> "This link does not identify a workspace file."
        LinkError.INVALID_WEB_URL -> "This web link is missing a hostname."
        LinkError.INVALID_WORKSPACE -> "The conversation's workspace path is unavailable."
        LinkError.OUTSIDE_WORKSPACE -> "This file is outside the conversation's workspace."
        LinkError.UNSUPPORTED_FILE_HOST -> "This file link points to a different machine."
        LinkError.UNSUPPORTED_SCHEME -> "Links using $scheme: cannot be opened in this pane."
        LinkError.INVALID_LINE -> "This file link has an invalid line or column number."
    }

    /**
     * Where [url] leads: an `http(s)` URL with a host, or a file inside
     * [workspaceRoot] (an absolute path). [relativeTo] is the current
     * document's workspace-relative or absolute path; relative links resolve
     * against its folder. Throws [LinkException].
     */
    fun resolve(url: String, workspaceRoot: String?, relativeTo: String? = null): ContentLink {
        val written = scheme.find(url)?.groupValues?.get(1)
        val schemeName = written?.lowercase()
        val fragmentStart = url.indexOf('#')
        val fragment = if (fragmentStart == -1) null else url.substring(fragmentStart + 1)
        // The URL without its fragment, then without its query.
        val reference = (if (fragmentStart == -1) url else url.substring(0, fragmentStart)).substringBefore('?')
        var encodedPath = when {
            written == null -> if (reference.startsWith("//")) throw LinkException(LinkError.UNSUPPORTED_FILE_HOST) else reference
            schemeName == "http" || schemeName == "https" -> {
                val rest = url.substring(written.length + 1)
                if (!rest.startsWith("//") || webHost(rest.drop(2)).isEmpty()) throw LinkException(LinkError.INVALID_WEB_URL)
                return ContentLink.Web(url)
            }
            schemeName == "file" -> {
                var rest = reference.substring(written.length + 1)
                if (rest.startsWith("//")) {
                    val host = rest.drop(2).substringBefore('/')
                    if (host.isNotEmpty() && !host.equals("localhost", ignoreCase = true)) throw LinkException(LinkError.UNSUPPORTED_FILE_HOST)
                    rest = rest.drop(2 + host.length)
                }
                if (!rest.startsWith("/")) throw LinkException(LinkError.INVALID_LINK)
                rest
            }
            // `README.md:12` parses as a scheme; only that file/line notation is accepted.
            written.contains('.') && !reference.contains("://") && lineSuffix.containsMatchIn(reference) -> reference
            else -> throw LinkException(LinkError.UNSUPPORTED_SCHEME, written)
        }
        val suffix = lineSuffix.find(encodedPath)
        if (suffix != null) encodedPath = encodedPath.substring(0, suffix.range.first)
        val path = decode(encodedPath) ?: throw LinkException(LinkError.INVALID_LINK)
        val range = fragment?.let { lineFragment.find(it) }
        var endLine: Int? = null
        val line = if (range != null) {
            positive(range.groupValues[1]).also { start ->
                val end = range.groupValues[2]
                if (end.isNotEmpty()) endLine = positive(end).also { if (it < start) throw LinkException(LinkError.INVALID_LINE) }
            }
        } else {
            suffix?.let { positive(it.groupValues[1]) }
        }
        // The column is not kept, but must be a valid number.
        val column = suffix?.groupValues?.get(2).orEmpty()
        if (column.isNotEmpty()) positive(column)

        val root = workspaceRoot?.takeIf { it.startsWith("/") && valid(it) }?.let { components(it) } ?: throw LinkException(LinkError.INVALID_WORKSPACE)
        val document = relativeTo?.takeIf { it.isNotEmpty() }?.let { walk(it, root, root) }
        val resolved = if (path.isEmpty() && fragment != null && document != null) document else walk(path, root, document?.dropLast(1) ?: root)
        if (resolved.size <= root.size) throw LinkException(LinkError.INVALID_LINK)
        return ContentLink.File(resolved.drop(root.size).joinToString("/"), line, endLine)
    }

    /** [path] as absolute components: absolute paths must lie inside [root]; relative ones walk from [base] and may never climb above [root]. */
    private fun walk(path: String, root: List<String>, base: List<String>): List<String> {
        if (path.isEmpty() || !valid(path)) throw LinkException(LinkError.INVALID_LINK)
        if (path.startsWith("/")) {
            val absolute = components(path) ?: throw LinkException(LinkError.OUTSIDE_WORKSPACE)
            if (absolute.size < root.size || absolute.subList(0, root.size) != root) throw LinkException(LinkError.OUTSIDE_WORKSPACE)
            return absolute
        }
        val result = base.toMutableList()
        for (part in path.split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (result.size <= root.size) throw LinkException(LinkError.OUTSIDE_WORKSPACE) else result.removeAt(result.lastIndex)
                else -> result += part
            }
        }
        return result
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

    /** No backslashes, control characters, or invisible format characters. */
    private fun valid(path: String): Boolean = path.none { it == '\\' || it.category == CharCategory.CONTROL || it.category == CharCategory.FORMAT }

    private fun positive(value: String): Int = value.toIntOrNull()?.takeIf { it > 0 } ?: throw LinkException(LinkError.INVALID_LINE)

    /** The host of an authority (after `//`), without user info or port; "" when missing. */
    private fun webHost(rest: String): String {
        val authority = rest.substringBefore('/').substringBefore('?').substringBefore('#').substringAfterLast('@')
        return if (authority.startsWith("[")) authority.substringBefore(']').drop(1) else authority.substringBefore(':')
    }

    /** Strict percent-decoding: null for a malformed escape or invalid UTF-8. A plus stays a plus. */
    private fun decode(value: String): String? {
        if ('%' !in value) return value
        val bytes = ArrayList<Byte>(value.length)
        var index = 0
        while (index < value.length) {
            if (value[index] != '%') {
                val next = value.indexOf('%', index).let { if (it == -1) value.length else it }
                value.substring(index, next).encodeToByteArray().forEach(bytes::add)
                index = next
                continue
            }
            if (index + 2 >= value.length) return null
            val high = hexDigit(value[index + 1])
            val low = hexDigit(value[index + 2])
            if (high < 0 || low < 0) return null
            bytes.add(((high shl 4) or low).toByte())
            index += 3
        }
        return runCatching { bytes.toByteArray().decodeToString(throwOnInvalidSequence = true) }.getOrNull()
    }

    private fun hexDigit(char: Char): Int = when (char) {
        in '0'..'9' -> char - '0'
        in 'a'..'f' -> char - 'a' + 10
        in 'A'..'F' -> char - 'A' + 10
        else -> -1
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

/**
 * Web links in prose: bare development addresses (`localhost:3000/path`,
 * opened over http) and explicit `http(s)://` URLs with a host, no user
 * info, and a valid port. Plain host names stay text, since they may be file
 * names. Trailing sentence punctuation and unbalanced closing brackets are
 * not part of a link. Ranges are UTF-16 and never overlap; the caller keeps
 * links the author wrote.
 */
object DetectedLinks {
    private val address = Regex("(?i)(?<![a-z0-9_./@:\\-])(?:localhost|\\[::1\\]|(?:[0-9]{1,3}\\.){3}[0-9]{1,3}):[0-9]{1,5}(?![a-z0-9_])(?:[/?#][^\\s<>\"`]+)?")
    private val web = Regex("(?i)(?<![a-z0-9+.\\-])https?://[^\\s<>\"`]+")

    data class Match(val range: IntRange, val url: String)

    /** Every link in [text], in order. */
    fun find(text: String): List<Match> {
        val addresses = address.findAll(text).mapNotNull { addressLink(it) }.toList()
        val urls = web.findAll(text).mapNotNull { webLink(it) }.filter { url ->
            addresses.none { it.range.first <= url.range.last && url.range.first <= it.range.last }
        }.toList()
        return if (urls.isEmpty()) addresses else (addresses + urls).sortedBy { it.range.first }
    }

    private fun addressLink(match: MatchResult): Match? {
        val value = trimmed(match.value, ".,;!")
        val host = value.substringBefore('/').substringBefore('?').substringBefore('#')
        val port = host.substringAfterLast(':').toIntOrNull() ?: return null
        if (port !in 1..65535) return null
        val octets = host.substringBeforeLast(':').split('.')
        if (octets.size == 4 && octets.any { (it.toIntOrNull() ?: 256) > 255 }) return null
        return Match(match.range.first until match.range.first + value.length, "http://$value")
    }

    private fun webLink(match: MatchResult): Match? {
        val value = trimmed(match.value, ".,;!?:'")
        val authority = value.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
        if ('@' in authority) return null
        val host: String
        val port: String
        if (authority.startsWith("[")) {
            val close = authority.indexOf(']')
            if (close == -1) return null
            val rest = authority.substring(close + 1)
            if (rest.isNotEmpty() && !rest.startsWith(":")) return null
            host = authority.substring(1, close)
            port = rest.removePrefix(":")
        } else {
            host = authority.substringBefore(':')
            port = authority.substringAfter(':', "")
        }
        if (host.isEmpty()) return null
        if (port.isNotEmpty() && (port.length > 5 || port.any { it !in '0'..'9' } || port.toInt() !in 1..65535)) return null
        return Match(match.range.first until match.range.first + value.length, value)
    }

    /** [value] without trailing [punctuation] or closing brackets that nothing in it opens. */
    private fun trimmed(value: String, punctuation: String): String {
        val closers = ")]}"
        val openers = "([{"
        val unbalanced = IntArray(3)
        for (char in value) {
            val opener = openers.indexOf(char)
            if (opener >= 0) unbalanced[opener]--
            val closer = closers.indexOf(char)
            if (closer >= 0) unbalanced[closer]++
        }
        var end = value.length
        while (end > 0) {
            val last = value[end - 1]
            if (last in punctuation) {
                end--
                continue
            }
            val closer = closers.indexOf(last)
            if (closer >= 0 && unbalanced[closer] > 0) {
                unbalanced[closer]--
                end--
                continue
            }
            break
        }
        return value.substring(0, end)
    }
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
