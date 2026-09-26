package com.dbpprt.dieter.data

import com.dbpprt.dieter.BuildConfig

/** Canonical Dieter release compared with the gateway's client floor. */
val DIETER_RELEASE_VERSION: String
    get() = BuildConfig.VERSION_NAME

/** Independent remote-desktop data-channel and native-helper protocol. */
const val DIETER_INPUT_PROTOCOL_VERSION = 3
