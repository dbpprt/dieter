package com.getdieter.android.update

import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** An update APK is installed only when its size and SHA-256 digest are the release's. */
class ApkVerifierTest {
    private val apk = "Dieter APK bytes for the verifier test".toByteArray()
    private val digest = "58d67d330bc8ce2e418211ab8a313c162e89f32b1014ad54fe0115e6f5ff0722"
    private val release =
        AppRelease(
            version = "0.5.0",
            downloadUrl = "https://github.com/dbpprt/dieter/releases/download/v0.5.0/x.apk",
            sha256 = digest,
            sizeBytes = apk.size.toLong(),
        )
    private val directory = Files.createTempDirectory("dieter-apk-test").toFile()

    @AfterTest fun cleanUp() = check(directory.deleteRecursively())

    /** Feeds [bytes] in chunks of [chunk], as the download loop does. */
    private fun ApkVerifier.download(bytes: ByteArray, chunk: Int = 7) {
        bytes.toList().chunked(chunk).forEach { part ->
            val buffer = part.toByteArray().copyOf(chunk + 3)
            update(buffer, part.size)
        }
    }

    private fun failure(block: () -> Unit) =
        assertFailsWith<IllegalStateException> { block() }.message

    @Test
    fun theReleasesBytesVerify() {
        val verifier = ApkVerifier(release)
        verifier.checkContentLength(apk.size.toLong())
        verifier.download(apk)
        assertEquals(apk.size.toLong(), verifier.total)
        verifier.verify()
    }

    @Test
    fun anUnknownLengthIsAllowedButAWrongOneIsNot() {
        ApkVerifier(release).checkContentLength(-1)
        ApkVerifier(release).checkContentLength(0)
        assertEquals(
            "The downloaded APK size does not match the GitHub release.",
            failure { ApkVerifier(release).checkContentLength(apk.size + 1L) },
        )
    }

    @Test
    fun otherBytesOfTheSameSizeAreRejected() {
        val tampered = apk.copyOf().also { it[it.size - 1] = (it.last() + 1).toByte() }
        val verifier = ApkVerifier(release)
        verifier.download(tampered)
        assertEquals(
            "The downloaded APK checksum does not match GitHub.",
            failure(verifier::verify),
        )
    }

    @Test
    fun anIncompleteDownloadIsRejected() {
        val verifier = ApkVerifier(release)
        verifier.download(apk.copyOf(apk.size - 1))
        assertEquals("The downloaded APK is incomplete.", failure(verifier::verify))
    }

    @Test
    fun aDownloadLargerThanTheReleaseStopsAtTheFirstExtraByte() {
        val verifier = ApkVerifier(release)
        verifier.download(apk)
        assertEquals(
            "The downloaded APK is larger than expected.",
            failure { verifier.update(byteArrayOf(0), 1) },
        )
    }

    @Test
    fun aCachedApkIsReusedOnlyWhenItsSizeAndDigestMatch() {
        val file = File(directory, release.apkFileName())
        assertFalse(ApkVerifier.matches(file, release), "missing")
        file.writeBytes(apk)
        assertTrue(ApkVerifier.matches(file, release))
        file.writeBytes(apk.reversedArray())
        assertFalse(ApkVerifier.matches(file, release), "same size, other bytes")
        file.writeBytes(apk + byteArrayOf(0))
        assertFalse(ApkVerifier.matches(file, release), "other size")
        assertFalse(ApkVerifier.matches(directory, release), "not a file")
    }

    @Test
    fun digestsAreLowercaseHexSha256() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ApkVerifier.sha256(ByteArrayInputStream("abc".toByteArray())),
        )
        val file = File(directory, "apk").apply { writeBytes(apk) }
        assertEquals(digest, ApkVerifier.sha256(file))
    }
}
