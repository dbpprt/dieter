package com.dbpprt.dieter.screens

import android.inputmethodservice.InputMethodService
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** A real docked IME window, independent of the emulator's physical-keyboard preferences. */
class DockedTestIme : InputMethodService() {
    override fun onEvaluateInputViewShown() = true
    override fun onEvaluateFullscreenMode() = false
    override fun onCreateInputView(): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(android.graphics.Color.rgb(35, 39, 48))
        val height = (280 * resources.displayMetrics.density).toInt()
        addView(TextView(context).apply {
            text = "Dieter test keyboard"
            setTextColor(android.graphics.Color.WHITE)
            gravity = android.view.Gravity.CENTER
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, height - (64 * resources.displayMetrics.density).toInt()))
        addView(Button(context).apply {
            text = "Enter"
            setOnClickListener { currentInputConnection?.commitText("\n", 1) }
        }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, (64 * resources.displayMetrics.density).toInt()))
    }
}
