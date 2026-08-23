package com.dbpprt.dieter.update

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.dbpprt.dieter.BuildConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject

data class AppRelease(
    val version: String,
    val downloadUrl: String,
    val sha256: String,
    val sizeBytes: Long,
)

sealed interface AppUpdateState {
    data object Idle : AppUpdateState
    data object Checking : AppUpdateState
    data class UpToDate(val version: String) : AppUpdateState
    data class Available(val release: AppRelease) : AppUpdateState
    data class Downloading(val release: AppRelease, val bytesDownloaded: Long) : AppUpdateState
    data class ReadyToInstall(
        val release: AppRelease,
        val apkPath: String,
        val installationAllowed: Boolean,
    ) : AppUpdateState

    data class Failed(val message: String, val release: AppRelease? = null) : AppUpdateState
}

class AppUpdateManager(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val releaseClient = GitHubReleaseClient()
    private val _state = MutableStateFlow<AppUpdateState>(AppUpdateState.Idle)
    val state = _state.asStateFlow()
    private val _promptVisible = MutableStateFlow(false)
    val promptVisible = _promptVisible.asStateFlow()
    private var operation: Job? = null
    private var automaticCheckStarted = false

    val currentVersion: String = BuildConfig.VERSION_NAME
    val automaticChecksEnabled: Boolean = !BuildConfig.DEBUG

    @Synchronized
    fun checkForUpdates(force: Boolean = false, showErrors: Boolean = false) {
        if (operation?.isActive == true) return
        if (!force && automaticCheckStarted) return
        if (!force) automaticCheckStarted = true
        _promptVisible.value = false
        operation = scope.launch {
            _state.value = AppUpdateState.Checking
            try {
                val release = releaseClient.latestRelease()
                if (!isNewerAppVersion(currentVersion, release.version)) {
                    clearCachedUpdates()
                    _state.value = AppUpdateState.UpToDate(currentVersion)
                    return@launch
                }
                val cached = cachedApk(release)
                _state.value = if (cached != null) {
                    readyState(release, cached)
                } else {
                    AppUpdateState.Available(release)
                }
                _promptVisible.value = true
            } catch (error: Throwable) {
                if (showErrors) {
                    _state.value = AppUpdateState.Failed(readableError(error))
                    _promptVisible.value = true
                } else {
                    _state.value = AppUpdateState.Idle
                }
            }
        }
    }

    @Synchronized
    fun downloadUpdate() {
        if (operation?.isActive == true) return
        val release = when (val current = _state.value) {
            is AppUpdateState.Available -> current.release
            is AppUpdateState.Failed -> current.release
            else -> null
        } ?: return
        _promptVisible.value = true
        operation = scope.launch {
            try {
                _state.value = AppUpdateState.Downloading(release, 0L)
                val apk = releaseClient.downloadApk(release, updateDirectory()) { downloaded ->
                    _state.value = AppUpdateState.Downloading(release, downloaded)
                }
                _state.value = readyState(release, apk)
            } catch (error: Throwable) {
                _state.value = AppUpdateState.Failed(readableError(error), release)
            }
        }
    }

    fun retry() {
        when (val current = _state.value) {
            is AppUpdateState.Failed -> {
                if (current.release == null) checkForUpdates(force = true, showErrors = true) else downloadUpdate()
            }
            else -> Unit
        }
    }

    fun showPrompt() {
        when (_state.value) {
            is AppUpdateState.Available,
            is AppUpdateState.Downloading,
            is AppUpdateState.ReadyToInstall,
            is AppUpdateState.Failed,
            -> _promptVisible.value = true
            else -> Unit
        }
    }

    fun dismissPrompt() {
        if (_state.value !is AppUpdateState.Downloading) _promptVisible.value = false
    }

    fun refreshInstallerPermission() {
        val current = _state.value as? AppUpdateState.ReadyToInstall ?: return
        val allowed = canRequestPackageInstalls()
        if (allowed != current.installationAllowed) {
            _state.value = current.copy(installationAllowed = allowed)
        }
    }

    fun openInstallPermissionSettings() {
        val release = (_state.value as? AppUpdateState.ReadyToInstall)?.release
        try {
            appContext.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, "package:${appContext.packageName}".toUri())
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (error: Throwable) {
            _state.value = AppUpdateState.Failed(readableError(error), release)
            _promptVisible.value = true
        }
    }

    fun installDownloadedUpdate() {
        val current = _state.value as? AppUpdateState.ReadyToInstall ?: return
        if (!canRequestPackageInstalls()) {
            refreshInstallerPermission()
            return
        }
        try {
            val apk = File(current.apkPath)
            check(apk.isFile) { "The downloaded update is no longer available." }
            val uri = FileProvider.getUriForFile(
                appContext,
                "${appContext.packageName}.updates",
                apk,
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newRawUri("Dieter update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(installIntent)
        } catch (error: Throwable) {
            _state.value = AppUpdateState.Failed(readableError(error), current.release)
            _promptVisible.value = true
        }
    }

    private fun readyState(release: AppRelease, apk: File): AppUpdateState.ReadyToInstall =
        AppUpdateState.ReadyToInstall(
            release = release,
            apkPath = apk.absolutePath,
            installationAllowed = canRequestPackageInstalls(),
        )

    private fun canRequestPackageInstalls(): Boolean =
        runCatching { appContext.packageManager.canRequestPackageInstalls() }.getOrDefault(false)

    private fun updateDirectory(): File = File(appContext.cacheDir, UPDATE_DIRECTORY).also { directory ->
        check(directory.isDirectory || (!directory.exists() && directory.mkdirs())) {
            "Could not prepare the update download directory."
        }
    }

    private fun clearCachedUpdates() {
        updateDirectory().listFiles()?.forEach { it.delete() }
    }

    private fun cachedApk(release: AppRelease): File? {
        val file = File(updateDirectory(), release.apkFileName())
        if (!file.isFile || file.length() != release.sizeBytes) return null
        return file.takeIf { releaseClient.sha256(it) == release.sha256 }
    }

    private fun readableError(error: Throwable): String =
        error.message?.substringBefore('\n')?.takeIf(String::isNotBlank) ?: "The update could not be completed."

    private companion object {
        const val UPDATE_DIRECTORY = "updates"
    }
}

private class GitHubReleaseClient {
    fun latestRelease(): AppRelease {
        val connection = openConnection(LATEST_RELEASE_URL, "application/vnd.github+json", API_TIMEOUT_MS)
        return connection.useSuccessfulResponse { response ->
            val body = response.inputStream.use(::readReleaseJson)
            val release = JSONObject(body)
            val tag = release.getString("tag_name")
            val version = tag.removePrefix("v")
            require(AppVersion.parse(version) != null) { "GitHub returned an invalid release version." }
            val assets = release.getJSONArray("assets")
            val apkAsset = (0 until assets.length())
                .asSequence()
                .map(assets::getJSONObject)
                .firstOrNull { it.optString("name") == APK_ASSET_NAME }
                ?: error("The latest GitHub release has no $APK_ASSET_NAME asset.")
            val digest = apkAsset.optString("digest").removePrefix(SHA256_PREFIX)
            require(SHA256.matches(digest)) { "The GitHub release has no valid APK checksum." }
            val size = apkAsset.getLong("size")
            require(size in 1..MAX_APK_BYTES) { "The GitHub release APK has an invalid size." }
            val downloadUrl = apkAsset.getString("browser_download_url")
            requireTrustedDownloadUrl(downloadUrl)
            AppRelease(
                version = version,
                downloadUrl = downloadUrl,
                sha256 = digest,
                sizeBytes = size,
            )
        }
    }

    fun downloadApk(release: AppRelease, directory: File, onProgress: (Long) -> Unit): File {
        requireTrustedDownloadUrl(release.downloadUrl)
        val target = File(directory, release.apkFileName())
        val partial = File(directory, "${target.name}.part")
        directory.listFiles()?.forEach { file ->
            if (file != target && file != partial) file.delete()
        }
        partial.delete()

        val connection = openConnection(release.downloadUrl, APK_MIME_TYPE, DOWNLOAD_TIMEOUT_MS)
        try {
            val status = connection.responseCode
            check(status in 200..299) { "GitHub returned HTTP $status while downloading the update." }
            val contentLength = connection.contentLengthLong
            check(contentLength <= 0 || contentLength == release.sizeBytes) {
                "The downloaded APK size does not match the GitHub release."
            }
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            var lastPercent = -1
            connection.inputStream.use { input ->
                FileOutputStream(partial).buffered().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        check(total <= release.sizeBytes) { "The downloaded APK is larger than expected." }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        val percent = ((total * 100) / release.sizeBytes).toInt()
                        if (percent != lastPercent) {
                            lastPercent = percent
                            onProgress(total)
                        }
                    }
                }
            }
            check(total == release.sizeBytes) { "The downloaded APK is incomplete." }
            check(digest.digest().toHex() == release.sha256) { "The downloaded APK checksum does not match GitHub." }
            target.delete()
            check(partial.renameTo(target)) { "Could not finish the update download." }
            return target
        } catch (error: Throwable) {
            partial.delete()
            throw error
        } finally {
            connection.disconnect()
        }
    }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().toHex()
    }

    private fun openConnection(url: String, accept: String, timeoutMs: Int): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = timeoutMs
            readTimeout = timeoutMs
            instanceFollowRedirects = true
            requestMethod = "GET"
            setRequestProperty("Accept", accept)
            setRequestProperty("Accept-Encoding", "identity")
            setRequestProperty("User-Agent", "Dieter-Android/${BuildConfig.VERSION_NAME}")
            setRequestProperty("X-GitHub-Api-Version", GITHUB_API_VERSION)
        }

    private fun <T> HttpURLConnection.useSuccessfulResponse(block: (HttpURLConnection) -> T): T = try {
        val status = responseCode
        check(status in 200..299) { "GitHub returned HTTP $status while checking for updates." }
        block(this)
    } finally {
        disconnect()
    }

    private fun readReleaseJson(input: java.io.InputStream): String {
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

    private fun requireTrustedDownloadUrl(value: String) {
        val url = URL(value)
        require(url.protocol == "https") { "The GitHub release download is not HTTPS." }
        require(url.host == "github.com") { "The GitHub release download host is invalid." }
    }

    private fun ByteArray.toHex(): String = joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private companion object {
        const val LATEST_RELEASE_URL = "https://api.github.com/repos/dbpprt/dieter/releases/latest"
        const val APK_ASSET_NAME = "Dieter-Android.apk"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val SHA256_PREFIX = "sha256:"
        const val GITHUB_API_VERSION = "2026-03-10"
        const val API_TIMEOUT_MS = 15_000
        const val DOWNLOAD_TIMEOUT_MS = 120_000
        const val MAX_RELEASE_JSON_BYTES = 1_048_576
        const val MAX_APK_BYTES = 250L * 1024 * 1024
        val SHA256 = Regex("^[0-9a-f]{64}$")
    }
}

private fun AppRelease.apkFileName(): String = "Dieter-Android-$version.apk"
