plugins {
    id("dieter.kmp")
}

kotlin {
    sourceSets {
        commonMain.dependencies {
            api(project(":shared"))
            api(kotlin("test"))
            api(libs.kotlinx.coroutines.test)
            api(libs.okio.fakefilesystem)
        }
        jvmMain.dependencies {
            implementation(libs.okhttp)
        }
    }
}
