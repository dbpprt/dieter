package com.dbpprt.dieter.settings

import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class DieterLauncherIconTest {
    @Test
    fun preferenceHydrationResolvesAliasesInTheInstalledVariant() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        // Synchronous hydration applies the persisted palette to every real
        // manifest alias. The screenFixture variant has an application ID
        // different from those aliases' class namespace.
        AppPreferences(context)
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        assertNotNull("The installed variant must retain an enabled launcher", launch)
        val component = requireNotNull(launch?.component)
        assertEquals(context.packageName, component.packageName)
        @Suppress("DEPRECATION")
        val activity = context.packageManager.getActivityInfo(component, 0)
        assertEquals(MainActivity::class.java.name, activity.targetActivity)
    }
}
