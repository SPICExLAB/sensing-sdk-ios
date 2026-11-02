// scripts/compat.sh runs this with the Android SDK's own Gradle wrapper. It builds Android's real FrameCodec.kt and its
// real proto with Wire, without changing anything in that repo.
pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories { mavenCentral() }
}

rootProject.name = "android-compat"
