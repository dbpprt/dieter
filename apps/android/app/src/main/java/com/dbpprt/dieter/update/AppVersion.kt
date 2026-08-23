package com.dbpprt.dieter.update

internal data class AppVersion(
    val major: Int,
    val minor: Int,
    val patch: Int,
) : Comparable<AppVersion> {
    override fun compareTo(other: AppVersion): Int =
        compareValuesBy(this, other, AppVersion::major, AppVersion::minor, AppVersion::patch)

    companion object {
        private val pattern = Regex("^v?(\\d+)\\.(\\d+)\\.(\\d+)(?:[-+].*)?$")

        fun parse(value: String): AppVersion? {
            val match = pattern.matchEntire(value.trim()) ?: return null
            return AppVersion(
                major = match.groupValues[1].toIntOrNull() ?: return null,
                minor = match.groupValues[2].toIntOrNull() ?: return null,
                patch = match.groupValues[3].toIntOrNull() ?: return null,
            )
        }
    }
}

internal fun isNewerAppVersion(current: String, candidate: String): Boolean {
    val currentVersion = requireNotNull(AppVersion.parse(current)) { "Invalid installed version: $current" }
    val candidateVersion = requireNotNull(AppVersion.parse(candidate)) { "Invalid release version: $candidate" }
    return candidateVersion > currentVersion
}
