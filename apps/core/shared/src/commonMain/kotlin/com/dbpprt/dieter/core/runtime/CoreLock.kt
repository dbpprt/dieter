package com.dbpprt.dieter.core.runtime

/** A mutual-exclusion lock for state shared with platform callback threads, such as a video decoder's. */
expect class CoreLock() {
    fun <T> locked(block: () -> T): T
}
