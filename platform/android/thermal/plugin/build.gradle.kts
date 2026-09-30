// WestboundThermal Android plugin (WP9.1). UNTESTED: `./gradlew :plugin:assemble` builds
// plugin/build/outputs/aar/plugin-{debug,release}.aar (docs/QUALITY.md -> Native plugins).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

// Must match the engine version of the export templates.
val godotVersion = "4.7.0.stable"

android {
    namespace = "com.westbound.thermal"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    compileOnly("org.godotengine:godot:$godotVersion")
}
