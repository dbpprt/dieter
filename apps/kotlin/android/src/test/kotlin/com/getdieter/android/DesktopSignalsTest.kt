package com.getdieter.android

import android.content.res.Configuration
import android.view.Display
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Which windows count as a desktop for the Automatic interface. */
class DesktopSignalsTest {
    private val phone =
        DesktopSignals.Window(
            samsungDex = false,
            uiModeType = Configuration.UI_MODE_TYPE_NORMAL,
            pc = false,
            displayId = Display.DEFAULT_DISPLAY,
            configuration =
                "{1.0 ?mcc0mnc [en_US] ldltr sw411dp w411dp h890dp 420dpi nrml long port " +
                    "finger -keyb/v/h -nav/h winConfig={ mBounds=Rect(0, 0 - 1080, 2340) " +
                    "mWindowingMode=fullscreen mDisplayWindowingMode=fullscreen }}",
        )

    @Test
    fun aPhoneInItsOwnFullscreenWindowIsNoDesktop() {
        assertFalse(DesktopSignals.desktop(phone))
        assertFalse(
            DesktopSignals.desktop(
                phone.copy(
                    configuration = phone.configuration.replace("fullscreen", "multi-window")
                )
            )
        )
    }

    @Test
    fun deXDeskModeAndPcsAreDesktops() {
        assertTrue(DesktopSignals.desktop(phone.copy(samsungDex = true)))
        assertTrue(DesktopSignals.desktop(phone.copy(uiModeType = Configuration.UI_MODE_TYPE_DESK)))
        assertTrue(DesktopSignals.desktop(phone.copy(pc = true)))
    }

    @Test
    fun aConnectedDisplayAndDesktopWindowingAreDesktops() {
        assertTrue(DesktopSignals.desktop(phone.copy(displayId = 2)))
        assertTrue(
            DesktopSignals.desktop(
                phone.copy(
                    configuration =
                        phone.configuration.replace(
                            "mWindowingMode=fullscreen",
                            "mWindowingMode=freeform",
                        )
                )
            )
        )
    }
}
