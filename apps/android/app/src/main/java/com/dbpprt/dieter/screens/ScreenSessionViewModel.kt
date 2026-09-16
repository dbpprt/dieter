package com.dbpprt.dieter.screens

import android.app.Application
import androidx.lifecycle.AndroidViewModel

/** Retains the peer and canvas through Activity rotation, but never across leaving Screens. */
class ScreenSessionViewModel(application: Application) : AndroidViewModel(application) {
    private var session: ScreenController? = null
    fun controller(): ScreenController = session ?: ScreenController(getApplication()).also { session = it }
    fun leave() { session?.close(); session = null }
    override fun onCleared() { leave() }
}
