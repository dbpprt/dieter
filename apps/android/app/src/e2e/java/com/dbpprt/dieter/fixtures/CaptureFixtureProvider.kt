package com.dbpprt.dieter.fixtures

import android.content.ContentProvider
import android.content.ContentValues
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/** E2E variant only: grants and metadata come through a real Android provider. */
class CaptureFixtureProvider : ContentProvider() {
    override fun onCreate() = true
    private fun file(uri: Uri): File {
        val name = requireNotNull(uri.lastPathSegment)
        require(name.matches(Regex("[a-zA-Z0-9_.-]+")))
        if (name.startsWith("denied")) throw SecurityException("Permission to this file is unavailable. Choose it again.")
        return File(requireNotNull(context).filesDir, "capture-fixture/$name")
    }
    override fun getType(uri: Uri) = if (uri.lastPathSegment.orEmpty().endsWith(".png")) "image/png" else "text/plain"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?) =
        MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any?>(uri.lastPathSegment, if (uri.getQueryParameter("unknown") != null) null else file(uri).length()))
        }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor = ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read only")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("Read only")
}
