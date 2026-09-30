plugins {
    // Puts the Kotlin and Android Gradle plugins from build-logic on every module's classpath.
    id("dieter.kmp") apply false
    alias(libs.plugins.wire) apply false
}
