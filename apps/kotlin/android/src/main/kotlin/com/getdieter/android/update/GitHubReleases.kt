package com.getdieter.android.update

import com.getdieter.core.runtime.ReleaseVersion
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URL
import org.json.JSONObject

/**
 * Reading GitHub's latest release as an Android update: the version, and the APK asset with the
 * size and SHA-256 digest GitHub publishes for it. Everything the updater later verifies a download
 * against comes from here, so a malformed or untrusted release is rejected whole.
 */
internal object GitHubReleases {
    const val APK_ASSET_NAME = "Dieter-Android.apk"
    const val MAX_RELEASE_JSON_BYTES = 1_048_576
    const val MAX_APK_BYTES = 250L * 1024 * 1024
    private const val SHA256_PREFIX = "sha256:"
    private val SHA256 = Regex("^[0-9a-f]{64}$")

    /**
     * The update [body] (GitHub's release JSON) describes; fails when anything is missing or
     * invalid.
     */
    fun parse(body: String): AppRelease {
        val release = JSONObject(body)
        val tag = release.getString("tag_name")
        val version = tag.removePrefix("v")
        require(ReleaseVersion.parse(version) != null) {
            "GitHub returned an invalid release version."
        }
        val assets = release.getJSONArray("assets")
        val apkAsset =
            (0 until assets.length()).asSequence().map(assets::getJSONObject).firstOrNull {
                it.optString("name") == APK_ASSET_NAME
            } ?: error("The latest GitHub release has no $APK_ASSET_NAME asset.")
        val digest = apkAsset.optString("digest").removePrefix(SHA256_PREFIX)
        require(SHA256.matches(digest)) { "The GitHub release has no valid APK checksum." }
        val size = apkAsset.getLong("size")
        require(size in 1..MAX_APK_BYTES) { "The GitHub release APK has an invalid size." }
        val downloadUrl = apkAsset.getString("browser_download_url")
        requireTrustedDownloadUrl(downloadUrl)
        return AppRelease(
            version = version,
            downloadUrl = downloadUrl,
            sha256 = digest,
            sizeBytes = size,
            prerelease =
                release.optBoolean("prerelease") ||
                    release.optBoolean("draft") ||
                    '-' in version.substringBefore('+'),
        )
    }

    /**
     * Whether [release] is offered to an app at [currentVersion]: a newer stable release. Dev
     * prereleases (GitHub prereleases, drafts, or SemVer prerelease versions) never are.
     */
    fun offered(currentVersion: String, release: AppRelease): Boolean =
        !release.prerelease && ReleaseVersion.isNewer(currentVersion, release.version)

    /** Downloads come only from github.com over HTTPS. */
    fun requireTrustedDownloadUrl(value: String) {
        val url = URL(value)
        require(url.protocol == "https") { "The GitHub release download is not HTTPS." }
        require(url.host == "github.com") { "The GitHub release download host is invalid." }
    }

    /** [input] as UTF-8, refusing a response larger than [MAX_RELEASE_JSON_BYTES]. */
    fun readReleaseJson(input: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            check(total <= MAX_RELEASE_JSON_BYTES) { "The GitHub release response is too large." }
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }
}

/** Where a release's APK is cached; one file per version. */
internal fun AppRelease.apkFileName(): String = "Dieter-Android-$version.apk"
