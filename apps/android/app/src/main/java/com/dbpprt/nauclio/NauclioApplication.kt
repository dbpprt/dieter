package com.dbpprt.nauclio

import android.app.Application

class NauclioApplication : Application() {
    val container by lazy { NauclioContainer(this) }
}
