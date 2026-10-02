package com.dbpprt.dieter.e2e

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.captureToImage
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

/**
 * Screenshots and their text companions. The default directory is the app's
 * external files directory, which the e2e runner pulls into the case's
 * `captures/` after the run.
 */
object Evidence {
    val directory: File
        get() = requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null)) { "External files directory unavailable" }

    /** Writes [bitmap] as the PNG file [name]; the caller keeps owning the bitmap. */
    fun save(bitmap: Bitmap, name: String, directory: File = this.directory): File {
        directory.mkdirs()
        return File(directory, name).also { file ->
            file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) { "Could not encode $name" } }
        }
    }

    /** The whole display, including system bars, dialogs, the launcher and its widgets. */
    fun display(name: String, directory: File = this.directory): File {
        val bitmap = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()) { "Screenshot unavailable" }
        return try { save(bitmap, name, directory) } finally { bitmap.recycle() }
    }

    /** A text file next to a screenshot, such as a semantics tree or a state dump. */
    fun text(name: String, text: String, directory: File = this.directory): File {
        directory.mkdirs()
        return File(directory, name).also { it.writeText(text) }
    }
}

/** This node's pixels (usually `onRoot()`) as the PNG file [name]. */
fun SemanticsNodeInteraction.saveEvidence(name: String, directory: File = Evidence.directory): File =
    Evidence.save(captureToImage().asAndroidBitmap(), name, directory)
