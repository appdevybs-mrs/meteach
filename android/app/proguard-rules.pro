# Project-specific R8/Proguard rules.
# Start minimal to avoid runtime regressions; tighten only as needed.

# Keep stacktrace line numbers/source for better crash diagnostics.
-keepattributes SourceFile,LineNumberTable

# Keep raw sound resource (ybs_notify) used by flutter_local_notifications
# via RawResourceAndroidNotificationSound runtime string lookup.
-keepclassmembers class **.R$raw {
    public static int ybs_notify;
}
