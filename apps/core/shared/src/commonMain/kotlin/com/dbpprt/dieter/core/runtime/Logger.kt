package com.dbpprt.dieter.core.runtime

/** Forwarded to Logcat or os_log. Messages must already be scrubbed of tokens. */
interface CoreLogger {
    fun debug(tag: String, message: String) {}
    fun info(tag: String, message: String) {}
    fun warn(tag: String, message: String, error: Throwable? = null) {}
}

object SilentLogger : CoreLogger
