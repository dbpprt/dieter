package com.dbpprt.dieter.core.identity

/**
 * A Dieter gateway the user signs in to. Credentials are keyed by [origin],
 * which is also the key legacy Android, macOS, and iOS stores used.
 */
data class Gateway(val name: String, val host: String, val port: Int, val secure: Boolean) {
    val origin: String get() = "${if (secure) "https" else "http"}://$host:$port"

    /** Base URL for HTTP requests, omitting the default HTTPS port. */
    val httpBase: String get() = "${if (secure) "https" else "http"}://${hostForUrl()}${if (secure && port == 443) "" else ":$port"}"

    private fun hostForUrl() = if (host.contains(':')) "[$host]" else host

    /**
     * Moves only the retired public address. Tokens stay keyed by their
     * original origin, so the new gateway requires its own sign-in.
     */
    fun migrated(): Gateway =
        if (secure && port == 443 && host.equals("board.dbpprt.com", ignoreCase = true)) copy(host = DEFAULT.host) else this

    /** Plaintext is only for loopback development gateways. */
    val permitted: Boolean get() = secure || Hosts.isLoopback(host)

    companion object {
        val DEFAULT = Gateway("Dieter Gateway", "gateway.getdieter.com", 443, true)
        const val PLAINTEXT_DEFAULT_PORT = 4242

        /**
         * Parses `host`, `host:port`, `[v6]:port`, with an optional `https://`,
         * `grpcs://`, `http://`, or `grpc://` prefix. Secure addresses default to 443.
         */
        fun parse(value: String, name: String = "Custom"): Gateway? {
            var text = value.trim()
            val lower = text.lowercase()
            val secure = lower.startsWith("https://") || lower.startsWith("grpcs://")
            for (prefix in listOf("grpcs://", "https://", "grpc://", "http://")) {
                if (text.lowercase().startsWith(prefix)) text = text.substring(prefix.length)
            }
            if (text.isEmpty() || '/' in text) return null
            val defaultPort = if (secure) 443 else PLAINTEXT_DEFAULT_PORT
            if (text.startsWith("[")) {
                val close = text.indexOf(']')
                if (close <= 1) return null
                val host = text.substring(1, close)
                val suffix = text.substring(close + 1)
                if (suffix.isNotEmpty() && !suffix.startsWith(":")) return null
                val port = if (suffix.isEmpty()) defaultPort else suffix.drop(1).toIntOrNull() ?: return null
                return if (port in 1..65_535) Gateway(name, host, port, secure) else null
            }
            if (text.count { it == ':' } > 1) return null
            val colon = text.lastIndexOf(':')
            if (colon >= 0) {
                val host = text.substring(0, colon)
                val port = text.substring(colon + 1).toIntOrNull() ?: return null
                return if (host.isNotEmpty() && port in 1..65_535) Gateway(name, host, port, secure) else null
            }
            return Gateway(name, text, defaultPort, secure)
        }
    }
}

/** An edited gateway entry: its address and label as typed, keyed by [id]. */
data class GatewayDraft(val id: String, val label: String, val address: String) {
    companion object {
        fun of(gateway: Gateway) = GatewayDraft(gateway.origin, gateway.name, gateway.httpBase)
    }
}

/** A gateway list being edited in settings: parsed, validated, and ready to save. */
data class GatewayEdits(val drafts: List<GatewayDraft>) {
    val parsed: List<Gateway?> = drafts.map { Gateway.parse(it.address, it.label.trim().ifBlank { "Custom" }) }

    /** Why the list cannot be saved, or null. */
    val problem: String? = when {
        drafts.isEmpty() -> "Keep at least one connection."
        parsed.any { it == null } -> "Enter a gateway address such as https://gateway.example.com."
        parsed.any { it?.permitted == false } -> "Remote gateways must use HTTPS."
        parsed.mapNotNull { it?.origin?.lowercase() }.distinct().size != drafts.size -> "Connection addresses must be unique."
        else -> null
    }

    val gateways: List<Gateway> get() = parsed.filterNotNull()

    /** The origin to activate: the chosen draft's, else the first gateway's. */
    fun activeOrigin(activeDraftId: String): String? =
        parsed.getOrNull(drafts.indexOfFirst { it.id == activeDraftId })?.origin ?: gateways.firstOrNull()?.origin
}

object Hosts {
    /** Literal loopback addresses only; host names other than localhost are never resolved. */
    fun isLoopback(value: String): Boolean {
        var host = value.lowercase()
        if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length - 1)
        if (host == "localhost" || host == "localhost.") return true
        ipv4(host)?.let { return it[0] == 127 }
        val v6 = ipv6(host) ?: return false
        return (v6.dropLast(1).all { it == 0 } && v6.last() == 1) ||
            (v6.take(5).all { it == 0 } && v6[5] == 0xffff && (v6[6] shr 8) == 127)
    }

    private fun ipv4(value: String): IntArray? {
        val parts = value.split('.')
        if (parts.size != 4) return null
        return IntArray(4) { index ->
            val part = parts[index]
            if (part.isEmpty() || part.length > 3 || !part.all(Char::isDigit)) return null
            part.toInt().takeIf { it in 0..255 } ?: return null
        }
    }

    /** Eight 16-bit groups, or null when [value] is not an IPv6 literal. */
    private fun ipv6(value: String): IntArray? {
        if (':' !in value) return null
        var text = value.substringBefore('%')
        var v4Tail = emptyList<Int>()
        val lastColon = text.lastIndexOf(':')
        val lastPart = text.substring(lastColon + 1)
        if ('.' in lastPart) {
            val v4 = ipv4(lastPart) ?: return null
            v4Tail = listOf((v4[0] shl 8) or v4[1], (v4[2] shl 8) or v4[3])
            text = text.substring(0, lastColon + 1)
            if (!text.endsWith("::")) text = text.dropLast(1)
        }
        val halves = text.split("::")
        if (halves.size > 2) return null
        fun groups(part: String): List<Int>? = if (part.isEmpty()) emptyList() else part.split(':').map { group ->
            if (group.isEmpty() || group.length > 4) return null
            group.toIntOrNull(16) ?: return null
        }
        val head = groups(halves[0]) ?: return null
        val rest = if (halves.size == 2) groups(halves[1]) ?: return null else emptyList()
        val explicit = head.size + rest.size + v4Tail.size
        val all = if (halves.size == 2) {
            if (explicit > 7) return null
            head + List(8 - explicit) { 0 } + rest + v4Tail
        } else {
            if (explicit != 8) return null
            head + v4Tail
        }
        return all.toIntArray()
    }
}
