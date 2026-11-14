package com.getdieter.core.folders

import platform.Foundation.NSString
import platform.Foundation.precomposedStringWithCanonicalMapping

@Suppress("CAST_NEVER_SUCCEEDS")
internal actual fun nfc(value: String): String =
    if (value.all { it.code < 0x300 }) value
    else (value as NSString).precomposedStringWithCanonicalMapping
