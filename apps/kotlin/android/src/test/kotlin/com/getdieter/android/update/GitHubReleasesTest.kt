package com.getdieter.android.update

import java.io.ByteArrayInputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** GitHub's latest release, read as an Android update, and which releases are offered. */
class GitHubReleasesTest {
    private val digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private val url = "https://github.com/dbpprt/dieter/releases/download/v0.5.0/Dieter-Android.apk"

    private fun asset(
        name: String = GitHubReleases.APK_ASSET_NAME,
        digest: Any? = "sha256:${this.digest}",
        size: Long = 42_000_000,
        url: String = this.url,
    ) =
        JSONObject().apply {
            put("name", name)
            if (digest != null) put("digest", digest)
            put("size", size)
            put("browser_download_url", url)
        }

    private fun release(
        tag: String = "v0.5.0",
        assets: List<JSONObject> = listOf(asset()),
        configure: JSONObject.() -> Unit = {},
    ): String =
        JSONObject()
            .apply {
                put("tag_name", tag)
                put("assets", JSONArray(assets))
                configure()
            }
            .toString()

    private fun rejected(body: String): String? =
        assertFailsWith<IllegalArgumentException> { GitHubReleases.parse(body) }.message

    @Test
    fun aReleaseNamesItsVersionApkSizeAndDigest() {
        assertEquals(
            AppRelease(
                version = "0.5.0",
                downloadUrl = url,
                sha256 = digest,
                sizeBytes = 42_000_000,
                prerelease = false,
            ),
            GitHubReleases.parse(release()),
        )
        assertEquals("0.5.0", GitHubReleases.parse(release(tag = "0.5.0")).version)
    }

    @Test
    fun onlyTheAndroidApkAssetIsUsed() {
        val parsed =
            GitHubReleases.parse(
                release(
                    assets =
                        listOf(
                            asset(name = "Dieter-macOS.zip", digest = "sha256:" + "0".repeat(64)),
                            asset(),
                            asset(name = "Dieter-Android.apk.sig", size = 10),
                        )
                )
            )
        assertEquals(digest, parsed.sha256)
        assertEquals(
            "The latest GitHub release has no Dieter-Android.apk asset.",
            assertFailsWith<IllegalStateException> {
                    GitHubReleases.parse(
                        release(assets = listOf(asset(name = "dieter-android.apk")))
                    )
                }
                .message,
        )
    }

    @Test
    fun aReleaseWithoutAValidVersionChecksumSizeOrTrustedUrlIsRejected() {
        assertEquals("GitHub returned an invalid release version.", rejected(release("main-123")))
        assertEquals("GitHub returned an invalid release version.", rejected(release("v0.5")))
        val checksum = "The GitHub release has no valid APK checksum."
        for (value in
            listOf(
                null,
                "",
                "sha256:${digest.uppercase()}",
                "sha256:${digest.drop(1)}",
                "sha512:$digest",
                "sha256:${digest.dropLast(1)}g",
            )) {
            assertEquals(
                checksum,
                rejected(release(assets = listOf(asset(digest = value)))),
                "$value",
            )
        }
        val size = "The GitHub release APK has an invalid size."
        assertEquals(size, rejected(release(assets = listOf(asset(size = 0)))))
        assertEquals(size, rejected(release(assets = listOf(asset(size = -1)))))
        assertEquals(
            size,
            rejected(release(assets = listOf(asset(size = GitHubReleases.MAX_APK_BYTES + 1)))),
        )
        GitHubReleases.parse(release(assets = listOf(asset(size = GitHubReleases.MAX_APK_BYTES))))
        assertEquals(
            "The GitHub release download is not HTTPS.",
            rejected(release(assets = listOf(asset(url = url.replace("https:", "http:"))))),
        )
        for (host in
            listOf(
                "https://objects.githubusercontent.com/Dieter-Android.apk",
                "https://github.com.example.org/Dieter-Android.apk",
                "https://evil.example/github.com/Dieter-Android.apk",
            )) {
            assertEquals(
                "The GitHub release download host is invalid.",
                rejected(release(assets = listOf(asset(url = host)))),
            )
        }
    }

    @Test
    fun malformedResponsesFail() {
        assertFailsWith<JSONException> { GitHubReleases.parse("not json") }
        assertFailsWith<JSONException> { GitHubReleases.parse("{}") }
        assertFailsWith<JSONException> { GitHubReleases.parse("""{"tag_name":"v0.5.0"}""") }
        assertFailsWith<JSONException> {
            GitHubReleases.parse(
                release(
                    assets =
                        listOf(
                            JSONObject()
                                .put("name", GitHubReleases.APK_ASSET_NAME)
                                .put("digest", "sha256:$digest")
                        )
                )
            )
        }
    }

    @Test
    fun onlyANewerStableReleaseIsOffered() {
        val stable = GitHubReleases.parse(release("v0.5.0"))
        assertTrue(GitHubReleases.offered("0.4.9", stable))
        assertFalse(GitHubReleases.offered("0.5.0", stable))
        assertFalse(GitHubReleases.offered("0.6.0", stable))
        // Dev prereleases are never offered, however GitHub marks them.
        for (body in
            listOf(
                release("v0.5.0") { put("prerelease", true) },
                release("v0.5.0") { put("draft", true) },
                release("v0.5.0-rc.1"),
            )) {
            val candidate = GitHubReleases.parse(body)
            assertTrue(candidate.prerelease, body)
            assertFalse(GitHubReleases.offered("0.4.9", candidate), body)
        }
        assertFalse(GitHubReleases.parse(release("v0.5.0+build.7")).prerelease)
        assertFailsWith<IllegalArgumentException> { GitHubReleases.offered("unknown", stable) }
    }

    @Test
    fun theReleaseResponseIsBounded() {
        val limit = GitHubReleases.MAX_RELEASE_JSON_BYTES
        val body = "é".repeat(limit / 2)
        assertEquals(body, GitHubReleases.readReleaseJson(ByteArrayInputStream(body.toByteArray())))
        assertEquals(
            "The GitHub release response is too large.",
            assertFailsWith<IllegalStateException> {
                    GitHubReleases.readReleaseJson(ByteArrayInputStream(ByteArray(limit + 1)))
                }
                .message,
        )
    }

    @Test
    fun eachVersionIsCachedUnderItsOwnName() {
        assertEquals(
            "Dieter-Android-0.5.0.apk",
            AppRelease("0.5.0", url, digest, 1).apkFileName(),
        )
    }
}
