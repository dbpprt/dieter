package com.getdieter.core.runtime

import java.time.ZoneId
import kotlin.time.Instant

actual fun localUtcOffsetSeconds(at: Instant): Int =
    ZoneId.systemDefault()
        .rules
        .getOffset(java.time.Instant.ofEpochMilli(at.toEpochMilliseconds()))
        .totalSeconds
