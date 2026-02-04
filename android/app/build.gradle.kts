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
        minSdk = flutter.minSdkVersion // Note: Desugaring usually requires minSdk 21+ for best results
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
    // ✅ UPDATED from 2.0.4 to 2.1.4 to fix the Build Failure
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
