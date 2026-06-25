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
