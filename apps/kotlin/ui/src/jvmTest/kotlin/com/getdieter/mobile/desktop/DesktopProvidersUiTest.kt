@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.desktop

import androidx.compose.ui.test.*
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * Providers in the desktop shell: the sidebar's usage meters open the Providers page, an account
 * opens its page with its machines, and Sign in starts a sign-in on that machine.
 */
class DesktopProvidersUiTest {
    @Test
    fun theSidebarMetersOpenProvidersAndAnAccountSignsInOnAMachine() =
        runDesktopComposeUiTest(width = 1440, height = 900) {
            val core = FakeMobileCore { command ->
                if (command.providers?.sign_in != null)
                    Result(provider_sign_in = ProviderSignInStarted("signin_mini"))
                else Result(done = Done())
            }
            val store = MobileStore(core, Dispatchers.Unconfined)
            store.layout.setInterfaceMode(InterfaceMode.AUTOMATIC)
            store.theme.setAppearance("light")
            DesktopFixture.publish(core)
            setContent { MobileApp(store, desktopHost = true) }
            waitForIdle()
            try {
                assertTrue(core.observing(Slice.SLICE_PROVIDERS), "the sidebar shows usage")
                DesktopFixture.publishProviders(core)
                waitForIdle()
                onNodeWithTag("sidebar-provider-claude").assertIsDisplayed()
                onAllNodesWithTag("sidebar-provider-chatgpt").assertCountEquals(0)

                onNodeWithTag("sidebar-provider-claude").performClick()
                waitForIdle()
                assertEquals(DesktopSection.PROVIDERS, store.routes.value.desktopPlace().section)
                onNodeWithTag("providers-add").assertIsDisplayed()
                onNodeWithTag("provider-pa_work").assertIsDisplayed()
                onNodeWithTag("provider-pa_personal").assertIsDisplayed()

                onNodeWithTag("provider-pa_personal").performClick()
                waitForIdle()
                assertEquals(MobileRoute.ProviderAccount("pa_personal"), store.routes.value.top)
                assertEquals(DesktopSection.PROVIDERS, store.routes.value.desktopPlace().section)
                onNodeWithTag("provider-machine-state-mini").assertTextEquals("Not signed in")
                onNodeWithTag("provider-signin-mini").performClick()
                waitForIdle()
                assertEquals(
                    listOf(ProvidersCommand(sign_in = ProviderSignInStart("pa_personal", "mini"))),
                    core.sentOf { it.providers }.filter { it.sign_in != null },
                )
            } finally {
                store.close()
            }
        }
}
