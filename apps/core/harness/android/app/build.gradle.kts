// The shared core's Android variant (OkHttp transport) in a minimal app,
// exercised on the JVM against the isolated gateway fixture.
plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.dbpprt.dieter.coreharness"
    compileSdk = 37
    compileSdkMinor = 1

    defaultConfig {
        applicationId = "com.dbpprt.dieter.coreharness"
        minSdk = 26
        targetSdk = 37
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("com.dbpprt.dieter:shared")
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.rules)
}

tasks.withType<Test>().configureEach {
    providers.gradleProperty("dieter.isolatedGateway").orNull?.let { systemProperty("dieter.isolatedGateway", it) }
    testLogging { events("passed", "failed", "skipped") }
}
