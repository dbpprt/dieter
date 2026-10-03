package com.dbpprt.dieter.core.composition

/**
 * The browser page a task capture records, and the projects or boards whose
 * hostnames route it. Hosts compare in the daemon's canonical form:
 * lowercase, without a trailing dot, IP literals as Go prints them.
 */
object CapturePages {
    private class Page(val url: String, val https: Boolean, val host: String, val port: Int?)

    /** [value] trimmed when it is an http(s) page with a host and a valid port, else null. */
    fun page(value: String): String? = parse(value)?.url

    /** The page's "host", or "host:port" when it names a port; IPv6 hosts with a port are bracketed. */
    fun hostname(value: String): String? {
        val page = parse(value) ?: return null
        return page.port?.let { address(page.host, it) } ?: page.host
    }

    /**
     * The indices of [candidates] (each one's hostnames) that route the page
     * at [url]: those naming its host and effective port, else those naming
     * only its host. Equally specific matches all count; the user chooses.
     */
    fun matches(url: String, candidates: List<List<String>>): List<Int> {
        val page = parse(url) ?: return emptyList()
        val address = address(page.host, page.port ?: if (page.https) 443 else 80)
        val exact = candidates.indices.filter { address in candidates[it] }
        return exact.ifEmpty { candidates.indices.filter { page.host in candidates[it] } }
    }

    private fun address(host: String, port: Int): String = "${if (':' in host) "[$host]" else host}:$port"

    private fun parse(value: String): Page? {
        val url = value.trim()
        val separator = url.indexOf("://")
        if (separator <= 0) return null
        val scheme = url.substring(0, separator).lowercase()
        if (scheme != "http" && scheme != "https") return null
        val rest = url.substring(separator + 3)
        val authority = rest.substring(0, rest.indexOfAny(charArrayOf('/', '?', '#')).let { if (it < 0) rest.length else it })
            .substringAfterLast('@')
        val rawHost: String
        val rawPort: String?
        if (authority.startsWith("[")) {
            val end = authority.indexOf(']')
            if (end < 0) return null
            rawHost = authority.substring(1, end)
            val tail = authority.substring(end + 1)
            rawPort = when {
                tail.isEmpty() -> null
                tail.startsWith(":") -> tail.substring(1)
                else -> return null
            }
        } else {
            if (authority.count { it == ':' } > 1) return null
            rawHost = authority.substringBefore(':')
            rawPort = if (':' in authority) authority.substringAfter(':') else null
        }
        val port = rawPort?.let { text ->
            if (text.isEmpty() || text.any { !it.isDigit() } || text.length > 5) return null
            text.toInt().takeIf { it in 1..65535 } ?: return null
        }
        val host = canonicalHost(rawHost) ?: return null
        return Page(url, scheme == "https", host, port)
    }

    /** Lowercase, without a trailing dot; IPv6 literals canonical, and IPv4-mapped ones as IPv4. */
    fun canonicalHost(raw: String): String? {
        var host = raw.lowercase()
        if (host.endsWith(".")) host = host.dropLast(1)
        if (host.isEmpty()) return null
        if (':' !in host) return host
        val bytes = ipv6(host) ?: return host
        if ((0 until 10).all { bytes[it] == 0 } && bytes[10] == 0xff && bytes[11] == 0xff) {
            return (12 until 16).joinToString(".") { bytes[it].toString() }
        }
        val words = (0 until 8).map { bytes[it * 2] shl 8 or bytes[it * 2 + 1] }
        var best = IntRange.EMPTY
        var start = 0
        while (start < words.size) {
            if (words[start] != 0) { start++; continue }
            var end = start + 1
            while (end < words.size && words[end] == 0) end++
            if (end - start > best.count()) best = start until end
            start = end
        }
        val groups = words.map { it.toString(16) }
        if (best.count() < 2) return groups.joinToString(":")
        return groups.subList(0, best.first).joinToString(":") + "::" + groups.subList(best.last + 1, groups.size).joinToString(":")
    }

    /** The 16 bytes of an IPv6 literal, or null when it is not one. */
    private fun ipv6(text: String): IntArray? {
        val parts = text.split("::")
        if (parts.size > 2) return null
        fun groups(part: String): List<Int>? {
            if (part.isEmpty()) return emptyList()
            val pieces = part.split(':')
            val words = mutableListOf<Int>()
            for ((index, piece) in pieces.withIndex()) {
                if (index == pieces.lastIndex && '.' in piece) {
                    val octets = piece.split('.').map { it.toIntOrNull()?.takeIf { value -> value in 0..255 } ?: return null }
                    if (octets.size != 4) return null
                    words += octets[0] shl 8 or octets[1]
                    words += octets[2] shl 8 or octets[3]
                } else {
                    if (piece.isEmpty() || piece.length > 4) return null
                    words += piece.toIntOrNull(16) ?: return null
                }
            }
            return words
        }
        val head = groups(parts[0]) ?: return null
        val tail = if (parts.size == 2) groups(parts[1]) ?: return null else emptyList()
        val words = if (parts.size == 2) {
            if (head.size + tail.size > 7) return null
            head + List(8 - head.size - tail.size) { 0 } + tail
        } else {
            head.takeIf { it.size == 8 } ?: return null
        }
        return IntArray(16) { index -> (words[index / 2] shr (if (index % 2 == 0) 8 else 0)) and 0xff }
    }
}
