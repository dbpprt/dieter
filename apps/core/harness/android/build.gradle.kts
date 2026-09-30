plugins {
    alias(libs.plugins.android.application) apply false
    // Puts Kotlin 2.4.10 on the classpath for AGP's built-in Kotlin, as the
    // app's Compose compiler plugin does. The core's metadata needs >= 2.4.
    alias(libs.plugins.compose.compiler) apply false
}
