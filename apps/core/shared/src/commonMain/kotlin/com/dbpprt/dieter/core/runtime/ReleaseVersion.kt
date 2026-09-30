package com.dbpprt.dieter.core.runtime

/** A canonical Dieter release, `vMAJOR.MINOR.PATCH`; build and prerelease suffixes are ignored. */
data class ReleaseVersion(val major: Int, val minor: Int, val patch: Int) : Comparable<ReleaseVersion> {
    override fun compareTo(other: ReleaseVersion): Int = compareValuesBy(this, other, ReleaseVersion::major, ReleaseVersion::minor, ReleaseVersion::patch)

    companion object {
        private val pattern = Regex("^v?(\\d+)\\.(\\d+)\\.(\\d+)(?:[-+].*)?$")

        fun parse(value: String): ReleaseVersion? {
            val match = pattern.matchEntire(value.trim()) ?: return null
            return ReleaseVersion(
                major = match.groupValues[1].toIntOrNull() ?: return null,
                minor = match.groupValues[2].toIntOrNull() ?: return null,
                patch = match.groupValues[3].toIntOrNull() ?: return null,
            )
        }

        /** Whether [candidate] is a newer release than the installed [current]; both must parse. */
        fun isNewer(current: String, candidate: String): Boolean {
            val installed = requireNotNull(parse(current)) { "Invalid installed version: $current" }
            val release = requireNotNull(parse(candidate)) { "Invalid release version: $candidate" }
            return release > installed
        }
    }
}
