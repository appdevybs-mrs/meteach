# Project-specific R8/Proguard rules.
# Start minimal to avoid runtime regressions; tighten only as needed.

# Keep stacktrace line numbers/source for better crash diagnostics.
-keepattributes SourceFile,LineNumberTable
