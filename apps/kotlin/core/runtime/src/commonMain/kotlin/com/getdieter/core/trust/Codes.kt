package com.getdieter.core.trust

/**
 * The short codes people read and type: unpadded Crockford base32 (MSB-first bit packing) in
 * hyphenated groups, compared ignoring case, separators and confusable characters. Device IDs and
 * pairing codes use it; `internal/security/codes` is the Go side.
 */
object Codes {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /** Unpadded Crockford base32. */
    fun encode(data: ByteArray): String {
        val out = StringBuilder((data.size * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for (value in data) {
            buffer = (buffer shl 8) or (value.toInt() and 0xFF)
            bits += 8
            while (bits >= 5) {
                bits -= 5
                out.append(ALPHABET[(buffer shr bits) and 31])
            }
            buffer = buffer and ((1 shl bits) - 1)
        }
        if (bits > 0) out.append(ALPHABET[(buffer shl (5 - bits)) and 31])
        return out.toString()
    }

    /** Typed Crockford base32 in any case, with or without separators; null when invalid. */
    fun decode(value: String): ByteArray? {
        val normalized = normalize(value)
        val out = ArrayList<Byte>(normalized.length * 5 / 8)
        var buffer = 0
        var bits = 0
        for (char in normalized) {
            val index = ALPHABET.indexOf(char)
            if (index < 0) return null
            buffer = (buffer shl 5) or index
            bits += 5
            if (bits >= 8) {
                bits -= 8
                out.add((buffer shr bits).toByte())
            }
            buffer = buffer and ((1 shl bits) - 1)
        }
        return out.toByteArray()
    }

    /** Splits [value] into hyphen-separated groups of [size]. */
    fun group(value: String, size: Int): String = value.chunked(size).joinToString("-")

    /**
     * Uppercases a typed code, drops separators and maps confusable characters onto the alphabet (O
     * to 0, I and L to 1).
     */
    fun normalize(value: String): String =
        buildString(value.length) {
            for (char in value.uppercase()) {
                when (char) {
                    '-',
                    ' ' -> {}
                    'O' -> append('0')
                    'I',
                    'L' -> append('1')
                    else -> append(char)
                }
            }
        }
}

/** Compares two byte arrays in time independent of where they differ. */
internal fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean {
    if (a.size != b.size) return false
    var difference = 0
    for (index in a.indices) difference = difference or (a[index].toInt() xor b[index].toInt())
    return difference == 0
}
