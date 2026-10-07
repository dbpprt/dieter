pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    versionCatalogs { create("coreLibs") { from(files("../../core/gradle/libs.versions.toml")) } }
}

rootProject.name = "DieterComposeSpike"

include(":app")

includeBuild("../../core")
