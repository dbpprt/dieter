package com.dbpprt.dieter.core.runtime

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.posix.arc4random_buf

@OptIn(ExperimentalForeignApi::class)
actual fun secureRandomBytes(count: Int): ByteArray {
    val bytes = ByteArray(count)
    if (count > 0) bytes.usePinned { arc4random_buf(it.addressOf(0), count.convert()) }
    return bytes
}
