package com.getdieter.android.update

import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/**
 * Checks an update APK against its release while it downloads: the announced length, a size that
 * never exceeds the release's, and finally the exact size and the SHA-256 digest GitHub published.
 * Only a verified file is handed to the system installer.
 */
internal class ApkVerifier(private val release: AppRelease) {
    private val digest = MessageDigest.getInstance("SHA-256")

    /** Bytes accepted so far. */
    var total = 0L
        private set

    /** The response's Content-Length; unknown (zero or negative) is allowed. */
    fun checkContentLength(contentLength: Long) {
        check(contentLength <= 0 || contentLength == release.sizeBytes) {
            "The downloaded APK size does not match the GitHub release."
        }
    }

    /** Accepts the next [count] bytes of [buffer], before they are written anywhere. */
    fun update(buffer: ByteArray, count: Int) {
        total += count
        check(total <= release.sizeBytes) { "The downloaded APK is larger than expected." }
        digest.update(buffer, 0, count)
    }

    /** Fails unless the whole APK arrived and its digest is the release's. */
    fun verify() {
        check(total == release.sizeBytes) { "The downloaded APK is incomplete." }
        check(digest.digest().toHex() == release.sha256) {
            "The downloaded APK checksum does not match GitHub."
        }
    }

    companion object {
        /** Whether [file] is [release]'s APK: its size and SHA-256 digest match. */
        fun matches(file: File, release: AppRelease): Boolean =
            file.isFile && file.length() == release.sizeBytes && sha256(file) == release.sha256

        /** [file]'s SHA-256 digest as lowercase hex. */
        fun sha256(file: File): String = file.inputStream().buffered().use(::sha256)

        fun sha256(input: InputStream): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
            return digest.digest().toHex()
        }

        private fun ByteArray.toHex(): String =
            joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }
}
