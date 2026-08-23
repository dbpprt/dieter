package com.dbpprt.dieter

import android.app.Application

class DieterApplication : Application() {
    val container by lazy { DieterContainer(this) }
}
