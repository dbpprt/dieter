package com.getdieter.core.runtime

import kotlin.time.Instant

/**
 * How many seconds the device's time zone is ahead of UTC at [at], daylight saving included. Rules
 * that word local days and times ("Today", "09:14") take it as a function, so tests choose a zone.
 */
expect fun localUtcOffsetSeconds(at: Instant): Int
