package com.dbpprt.dieter.core.runtime

import okio.ByteString.Companion.toByteString

/** Cryptographically secure random bytes from the platform. */
expect fun secureRandomBytes(count: Int): ByteArray

/** URL-safe base64 without padding, as used by PKCE (RFC 7636). */
fun ByteArray.base64Url(): String = toByteString().base64Url().trimEnd('=')

fun randomUrlToken(bytes: Int): String = secureRandomBytes(bytes).base64Url()
