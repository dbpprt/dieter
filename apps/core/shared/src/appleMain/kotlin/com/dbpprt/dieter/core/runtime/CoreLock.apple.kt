package com.dbpprt.dieter.core.runtime

import platform.Foundation.NSRecursiveLock

actual class CoreLock actual constructor() {
    private val lock = NSRecursiveLock()

    actual fun <T> locked(block: () -> T): T {
        lock.lock()
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}
