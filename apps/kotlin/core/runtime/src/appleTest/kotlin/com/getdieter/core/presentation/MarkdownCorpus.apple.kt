@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.getdieter.core.presentation

import platform.Foundation.NSFileManager
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.stringWithContentsOfFile

/**
 * The corpus in the repository: DIETER_REPOSITORY, else the closest parent of the working directory
 * or of the test binary (Gradle builds it inside the repository; simulators share the host's
 * files).
 */
private val corpus: String by lazy {
    val files = NSFileManager.defaultManager
    val starts =
        listOfNotNull(
            NSProcessInfo.processInfo.environment["DIETER_REPOSITORY"] as? String,
            files.currentDirectoryPath,
            NSProcessInfo.processInfo.arguments.firstOrNull() as? String,
        )
    for (start in starts) {
        var directory = start
        while (directory.isNotEmpty()) {
            val path = "$directory/tests/fixtures/markdown"
            if (files.fileExistsAtPath(path)) return@lazy path
            directory = directory.substringBeforeLast('/', "")
        }
    }
    error("tests/fixtures/markdown not found; set DIETER_REPOSITORY to the repository")
}

internal actual fun markdownFixtureNames(): List<String> =
    NSFileManager.defaultManager
        .contentsOfDirectoryAtPath(corpus, null)
        .orEmpty()
        .mapNotNull {
            (it as? String)?.takeIf { name -> name.endsWith(".md") }?.removeSuffix(".md")
        }
        .sorted()

internal actual fun markdownFixture(file: String): String =
    checkNotNull(NSString.stringWithContentsOfFile("$corpus/$file", NSUTF8StringEncoding, null)) {
        "$corpus/$file is unreadable"
    }
