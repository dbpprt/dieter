@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.getdieter.core.folders

import platform.Foundation.NSFileManager
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSString
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.stringWithContentsOfFile

/**
 * The golden vectors in the repository: DIETER_REPOSITORY, else the closest parent of the working
 * directory or of the test binary that has them.
 */
internal actual fun folderVectors(): String {
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
            val path = "$directory/tests/fixtures/folders/vectors.json"
            if (files.fileExistsAtPath(path))
                return checkNotNull(
                    NSString.stringWithContentsOfFile(path, NSUTF8StringEncoding, null)
                ) {
                    "$path is unreadable"
                }
            directory = directory.substringBeforeLast('/', "")
        }
    }
    error("tests/fixtures/folders/vectors.json not found; set DIETER_REPOSITORY to the repository")
}
