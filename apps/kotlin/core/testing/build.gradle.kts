plugins {
    id("dieter.kmp")
}

kotlin {
    sourceSets {
        commonMain.dependencies {
            api(project(":core:runtime"))
            api(kotlin("test"))
            api(libs.kotlinx.coroutines.test)
            api(libs.okio.fakefilesystem)
        }
        jvmMain.dependencies {
            implementation(libs.okhttp)
        }
    }
}
