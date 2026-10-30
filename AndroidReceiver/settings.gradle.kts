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
}

rootProject.name = "MeowDisplayAndroid"

// `core`: the secure receiver protocol in plain Kotlin/JVM (pairing v13,
// pinned TLS, framing, media frames), tested on the host against the Swift
// implementation's vectors. `app`: the Android receiver built on it.
include(":core", ":app")
