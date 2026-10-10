package com.dbpprt.dieter.screens

// A distinct provider class avoids colliding with the existing APK-update
// provider when Android instantiates providers in the same process.
class ScreenClipboardProvider : androidx.core.content.FileProvider()
