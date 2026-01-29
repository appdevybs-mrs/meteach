plugins {
    id("com.android.application")
    id("kotlin-android")

    // Flutter Gradle Plugin must be applied after Android + Kotlin
    id("dev.flutter.flutter-gradle-plugin")

    // ✅ Google Services (Firebase)
}

android {
    namespace = "com.dreamenglish.academy.dream_english_academy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.dreamenglish.academy.dream_english_academy"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
apply(plugin = "com.google.gms.google-services")
