package com.dbpprt.dieter.core.runtime

import java.security.SecureRandom

private val random = SecureRandom()

actual fun secureRandomBytes(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)
