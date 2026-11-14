package com.getdieter.core.runtime

import kotlin.time.Instant
import platform.Foundation.NSDate
import platform.Foundation.NSTimeZone
import platform.Foundation.dateWithTimeIntervalSince1970
import platform.Foundation.localTimeZone

actual fun localUtcOffsetSeconds(at: Instant): Int =
    NSTimeZone.localTimeZone
        .secondsFromGMTForDate(
            NSDate.dateWithTimeIntervalSince1970(at.toEpochMilliseconds() / 1000.0)
        )
        .toInt()
