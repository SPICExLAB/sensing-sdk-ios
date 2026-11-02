// Versions match sensing-sdk-android's gradle/libs.versions.toml.
plugins {
    kotlin("jvm") version "2.4.20"
    id("com.squareup.wire") version "7.0.3"
    application
}

val sdk = file("../../../sensing-sdk-android")

// A copy into build/, so nothing else in Android's storage module (which needs Android) comes along.
val copyFrameCodec by tasks.registering(Copy::class) {
    from(sdk.resolve("sensing-storage/src/main/java/com/rahulislam/sensing/storage/FrameCodec.kt"))
    into(layout.buildDirectory.dir("frame-codec"))
}

kotlin.sourceSets["main"].kotlin.srcDir(copyFrameCodec)

wire {
    sourcePath { srcDir(sdk.resolve("sensing-model/src/main/proto")) }
    kotlin {}
}

dependencies {
    implementation("com.squareup.wire:wire-runtime:7.0.3")
}

application {
    mainClass.set("MainKt")
}
