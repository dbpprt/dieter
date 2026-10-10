package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.core.identity.Hosts
import com.dbpprt.dieter.core.identity.Urls

/**
 * The embedded workspace browser's address rules. The user lists addresses
 * that open in the system browser instead: a bare host matches only that
 * host, `*.host` also matches its subdomains, and a full HTTP(S) URL matches
 * its scheme, host, and port, and its path as a prefix ending at a path
 * segment. Rules compare lowercased.
 */
object BrowserRules {
    private const val MAX_RULE_LENGTH = 512
    private const val HOST_CHARACTERS = "abcdefghijklmnopqrstuvwxyz0123456789-."
    private val schemePrefix = Regex("^([A-Za-z][A-Za-z0-9+.-]*)://")

    /** A parsed `scheme://authority/path` address; [path] is percent-decoded without a trailing slash. */
    private class Address(
        val scheme: String,
        val host: String,
        val port: Int?,
        val path: String,
        val userInfo: Boolean,
        val query: Boolean,
        val fragment: Boolean,
    )

    /** Whether an http(s) [url] opens in the system browser under [rules]. */
    fun matches(url: String, rules: List<String>): Boolean {
        val destination = parse(url) ?: return false
        if (destination.scheme != "http" && destination.scheme != "https") return false
        return rules.any { entry ->
            val rule = entry.trim().lowercase()
            val address = parse(rule)
            when {
                address != null -> {
                    val path = address.path.ifEmpty { "/" }
                    address.scheme == destination.scheme && address.host == destination.host && address.port == destination.port &&
                        (path == "/" || destination.path == path || destination.path.startsWith("$path/"))
                }
                rule.startsWith("*.") -> rule.drop(2).let { suffix -> destination.host == suffix || destination.host.endsWith(".$suffix") }
                else -> destination.host == rule
            }
        }
    }

    /**
     * The rule to store for what the user typed, or null when it is not a
     * host with a dot (optionally `*.`-prefixed) or an HTTP(S) URL without
     * user info, query, or fragment. Lowercased, at most 512 characters.
     */
    fun normalized(input: String): String? {
        val value = input.trim().lowercase()
        if (value.isEmpty() || value.length > MAX_RULE_LENGTH) return null
        if ("://" in value) {
            if (value.any { it.isWhitespace() || it in "<>\"{}|\\^`" }) return null
            val address = parse(value) ?: return null
            if (address.scheme != "http" && address.scheme != "https") return null
            if (address.userInfo || address.query || address.fragment) return null
            return value
        }
        val host = value.removePrefix("*.")
        if ('.' !in host || host.startsWith(".") || host.endsWith(".") || host.any { it !in HOST_CHARACTERS }) return null
        return value
    }

    /**
     * A claude.ai page in the user's own Claude account, such as a chat or an
     * artifact: https on claude.ai or www.claude.ai, without a port or user info.
     */
    fun isClaudeAccountPage(url: String): Boolean = claudePath(url) != null

    /** A Claude artifact (claude.ai/artifact/… or claude.ai/code/artifact/…). */
    fun isClaudeArtifact(url: String): Boolean =
        claudePath(url)?.let { it.startsWith("/artifact/") || it.startsWith("/code/artifact/") } == true

    /**
     * A Claude Design page: a claude.ai/design project or a Claude artifact,
     * where Claude Design now lives. Both need the user's claude.ai session.
     */
    fun isClaudeDesign(url: String): Boolean =
        claudePath(url)?.let { it == "/design" || it.startsWith("/design/") } == true || isClaudeArtifact(url)

    /**
     * Why an http(s) [url] opens in the system browser whatever the user's
     * rules say, for a client without a claude.ai session of its own; null
     * when it need not.
     */
    fun systemBrowserNotice(url: String): String? =
        if (isClaudeDesign(url)) "Claude artifacts and designs open in your default browser, where you are signed in to claude.ai." else null

    private fun claudePath(url: String): String? {
        val address = parse(url.trim()) ?: return null
        val claude = address.scheme == "https" && address.port == null && !address.userInfo &&
            (address.host == "claude.ai" || address.host == "www.claude.ai")
        return if (claude) address.path.ifEmpty { "/" } else null
    }

    /**
     * Whether a browser address's [host] is this machine: `localhost` and its
     * subdomains, `0.0.0.0`, `::`, any IPv4 form whose first octet is 127
     * (including `127.1` and `2130706433`), `::1`, and IPv4-mapped 127
     * addresses. Brackets and a trailing dot are ignored.
     */
    fun isLoopbackHost(host: String): Boolean {
        val value = host.lowercase().trim { it == '[' || it == ']' || it == '.' }
        if (value == "localhost" || value.endsWith(".localhost") || value == "0.0.0.0" || value == "::") return true
        ipv4(value)?.let { return it ushr 24 == 127L }
        return ':' in value && Hosts.isLoopback(value)
    }

    private fun parse(value: String): Address? {
        val scheme = schemePrefix.find(value) ?: return null
        val rest = value.substring(scheme.range.last + 1)
        val authorityEnd = rest.indexOfFirst { it == '/' || it == '?' || it == '#' }.let { if (it == -1) rest.length else it }
        val authority = rest.substring(0, authorityEnd)
        val hostAndPort = authority.substringAfterLast('@')
        val host: String
        val portText: String
        if (hostAndPort.startsWith("[")) {
            val close = hostAndPort.indexOf(']')
            if (close == -1) return null
            val after = hostAndPort.substring(close + 1)
            if (after.isNotEmpty() && !after.startsWith(":")) return null
            host = hostAndPort.substring(1, close)
            portText = after.removePrefix(":")
        } else {
            host = hostAndPort.substringBefore(':')
            portText = hostAndPort.substringAfter(':', "")
        }
        if (host.isEmpty()) return null
        val port = if (portText.isEmpty()) {
            null
        } else {
            if (portText.length > 5 || portText.any { it !in '0'..'9' }) return null
            portText.toInt()
        }
        val tail = rest.substring(authorityEnd)
        val fragmentStart = tail.indexOf('#')
        val beforeFragment = if (fragmentStart == -1) tail else tail.substring(0, fragmentStart)
        val queryStart = beforeFragment.indexOf('?')
        val rawPath = if (queryStart == -1) beforeFragment else beforeFragment.substring(0, queryStart)
        val path = Urls.decodePath(rawPath).let { if (it.length > 1 && it.endsWith('/')) it.dropLast(1) else it }
        return Address(
            scheme = scheme.groupValues[1].lowercase(),
            host = host.lowercase(),
            port = port,
            path = path,
            userInfo = '@' in authority,
            query = queryStart != -1,
            fragment = fragmentStart != -1,
        )
    }

    /** An IPv4 address in any form `inet_aton` reads (1 to 4 decimal, octal, or hex parts), as 32 bits; null otherwise. */
    private fun ipv4(value: String): Long? {
        val parts = value.split('.')
        if (parts.size > 4) return null
        val numbers = parts.map { number(it) ?: return null }
        val last = numbers.last()
        val leading = numbers.dropLast(1)
        if (leading.any { it > 0xFF }) return null
        if (last > (0xFFFFFFFFL ushr (8 * leading.size))) return null
        return leading.fold(0L) { address, octet -> (address shl 8) or octet }.shl(8 * (4 - leading.size)) or last
    }

    /** A C integer literal: `0x` hexadecimal, a leading `0` octal, else decimal. */
    private fun number(text: String): Long? {
        val (digits, radix) = when {
            text.startsWith("0x") -> text.substring(2) to 16
            text.length > 1 && text.startsWith("0") -> text.substring(1) to 8
            else -> text to 10
        }
        if (digits.isEmpty()) return if (radix == 16) 0L else null
        if (digits.length > 11) return null
        val allowed = when (radix) {
            16 -> "0123456789abcdef"
            8 -> "01234567"
            else -> "0123456789"
        }
        if (digits.any { it !in allowed }) return null
        return digits.toLong(radix)
    }
}
