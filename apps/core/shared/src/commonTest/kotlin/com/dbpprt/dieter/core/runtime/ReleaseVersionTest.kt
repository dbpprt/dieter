package com.dbpprt.dieter.core.runtime

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ReleaseVersionTest {
    @Test fun comparesSemanticVersionComponentsNumerically() {
        assertTrue(ReleaseVersion.isNewer("0.4.22", "v0.4.23"))
        assertTrue(ReleaseVersion.isNewer("0.9.99", "v1.0.0"))
        assertFalse(ReleaseVersion.isNewer("1.2.3", "v1.2.3"))
        assertFalse(ReleaseVersion.isNewer("1.2.4", "v1.2.3"))
    }

    @Test fun acceptsBuildAndPrereleaseSuffixesForInstalledBuilds() {
        assertFalse(ReleaseVersion.isNewer("0.4.22-debug", "v0.4.22"))
        assertTrue(ReleaseVersion.isNewer("0.4.22+local", "v0.4.23"))
    }

    @Test fun rejectsNonSemanticVersions() {
        assertNull(ReleaseVersion.parse("main-123"))
        assertNull(ReleaseVersion.parse("0.4"))
        assertNull(ReleaseVersion.parse("release"))
    }
}
