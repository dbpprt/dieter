package com.dbpprt.dieter.core.runtime

actual class CoreLock actual constructor() {
    actual fun <T> locked(block: () -> T): T = synchronized(this, block)
}
