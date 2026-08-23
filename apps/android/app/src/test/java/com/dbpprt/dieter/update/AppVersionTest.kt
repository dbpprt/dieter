package com.dbpprt.dieter.update

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppVersionTest {
    @Test
    fun comparesSemanticVersionComponentsNumerically() {
        assertTrue(isNewerAppVersion("0.4.22", "v0.4.23"))
        assertTrue(isNewerAppVersion("0.9.99", "v1.0.0"))
        assertFalse(isNewerAppVersion("1.2.3", "v1.2.3"))
        assertFalse(isNewerAppVersion("1.2.4", "v1.2.3"))
    }

    @Test
    fun acceptsBuildAndPrereleaseSuffixesForInstalledBuilds() {
        assertFalse(isNewerAppVersion("0.4.22-debug", "v0.4.22"))
        assertTrue(isNewerAppVersion("0.4.22+local", "v0.4.23"))
    }

    @Test
    fun rejectsNonSemanticVersions() {
        assertNull(AppVersion.parse("main-123"))
        assertNull(AppVersion.parse("0.4"))
        assertNull(AppVersion.parse("release"))
    }
}
