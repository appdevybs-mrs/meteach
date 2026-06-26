# Project-specific R8/Proguard rules.
# Start minimal to avoid runtime regressions; tighten only as needed.

# Keep stacktrace line numbers/source for better crash diagnostics.
-keepattributes SourceFile,LineNumberTable

# Keep raw sound resource (ybs_notify) used by flutter_local_notifications
# via RawResourceAndroidNotificationSound runtime string lookup.
-keepclassmembers class **.R$raw {
    public static int ybs_notify;
}

# Firebase - needed to prevent release build crashes
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Flutter engine
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }

# JSON serialization / Gson
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }

# Facebook SDK
-keep class com.facebook.** { *; }

# Flutter embedding references Play Core deferred component classes even when
# this app does not use deferred components. Suppress R8 missing-class warnings.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
