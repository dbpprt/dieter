@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.runDesktopComposeUiTest
import androidx.compose.ui.unit.dp
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * One frame of the refresh shimmer: light sweeping over a refreshing row's text. Tests run without
 * infinite animations, so this draws the band at a fixed point of its sweep.
 */
class RefreshShimmerUiTest {
    @Test
    fun theBandLightsOnlyWhatItCrosses() =
        runDesktopComposeUiTest(width = 320, height = 80) {
            val highlight = Color(0xFF0A84FF)
            setContent {
                Box(Modifier.background(Color.Black).padding(10.dp)) {
                    Box(
                        Modifier.testTag("shimmer")
                            .size(300.dp, 60.dp)
                            .shimmerBand(phase = .5f, strength = 1f, highlight = highlight)
                            .background(Color.White, RoundedCornerShape(30.dp))
                    )
                }
            }
            waitForIdle()
            val image = onNodeWithTag("shimmer").captureToImage().toAwtImage()
            System.getProperty("dieter.screenshots")?.let { directory ->
                File(directory).mkdirs()
                ImageIO.write(image, "png", File(directory, "refresh-shimmer-band.png"))
            }
            fun rgb(x: Int, y: Int) =
                image.getRGB(x, y).let { Triple(it shr 16 and 255, it shr 8 and 255, it and 255) }
            val middle = image.height / 2
            // At its centre the band tints the white pill towards the highlight.
            val (r, g, b) = rgb(image.width / 2, middle)
            assertTrue(b > 200 && r < 120, "the band's centre is lit: ${Triple(r, g, b)}")
            // Near the pill's ends, far from the band's centre, it stays almost white.
            val (er, eg, eb) = rgb(image.width / 20 + 15, middle)
            assertTrue(
                er > 200 && eg > 200 && eb > 200,
                "the pill's end stays white: ${Triple(er, eg, eb)}",
            )
            // Outside what the content draws (the pill's rounded corner) the band adds nothing: the
            // black behind it shows.
            assertEquals(
                Triple(0, 0, 0),
                rgb(1, middle / 4),
                "the corner outside the pill stays black",
            )
        }
}
