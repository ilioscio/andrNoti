plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.ilios.aisthetron.watch"
    compileSdk = 35

    defaultConfig {
        // Same applicationId as the phone app so the Wear Data Layer treats
        // them as one connected app (requires matching signing key too).
        applicationId = "dev.ilios.aisthetron"
        minSdk = 30
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            // Debug-signed for now, matching the phone app so Data Layer pairs.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    // Wear OS health sensors (passive monitoring)
    implementation("androidx.health:health-services-client:1.1.0-rc02")
    // Wear Data Layer (send samples to the paired phone)
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    // Health Services returns Guava ListenableFuture but declares it as
    // `implementation`, so consumers must put it on the compile classpath.
    implementation("com.google.guava:guava:33.3.1-android")
}
