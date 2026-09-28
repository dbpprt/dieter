package com.dbpprt.dieter.fixtures

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button

/** A separate sending component: Android excludes the caller from its share targets. */
class CaptureShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(Button(this).apply {
            text = "Share screenshot"
            setOnClickListener {
                val uri = Uri.parse(intent.getStringExtra("uri"))
                val send = Intent(Intent.ACTION_SEND).setType("image/png").setPackage(packageName)
                    .putExtra(Intent.EXTRA_STREAM, uri).putExtra(Intent.EXTRA_TEXT, "Review this screenshot")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                send.clipData = ClipData.newUri(contentResolver, "screenshot", uri)
                startActivity(Intent.createChooser(send, "Share screenshot"))
            }
        })
    }
}

class CaptureAlternativeActivity : Activity()
