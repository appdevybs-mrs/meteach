import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")

    // Flutter Gradle Plugin must be applied after Android + Kotlin
    id("dev.flutter.flutter-gradle-plugin")

    // ✅ Google Services (Firebase) plugin
    id("com.google.gms.google-services")
}

android {
    namespace = "com.dreamenglish.academy.dream_english_academy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // ✅ Keep your Java 17
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17

        // ✅ REQUIRED for flutter_local_notifications (desugaring)
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        // ✅ Keep Kotlin target 17
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.dreamenglish.academy.dream_english_academy"

        // ✅ WebRTC requires minSdk 21+
        minSdk = flutter.minSdkVersion

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // NOTE: for real release you should configure a release keystore later
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // ✅ keep desugaring
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
