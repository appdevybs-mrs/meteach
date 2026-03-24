#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_BIN="/mnt/shared/YBSAPP/flutter/bin/flutter"

if [ ! -x "$FLUTTER_BIN" ]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
  else
    echo "Flutter not found. Install Flutter first."
    exit 1
  fi
fi

SDK_DIR="${ANDROID_SDK_ROOT:-}"
if [ -z "$SDK_DIR" ] && [ -d "/home/misters/Android/Sdk" ]; then
  SDK_DIR="/home/misters/Android/Sdk"
fi

if [ -z "$SDK_DIR" ] || [ ! -d "$SDK_DIR" ]; then
  echo "Android SDK not found. Set ANDROID_SDK_ROOT to your SDK path."
  exit 1
fi

export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_HOME="$SDK_DIR"

cd "$PROJECT_DIR"

echo "Using Android SDK: $SDK_DIR"

SDKMANAGER="$SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
if [ -x "$SDKMANAGER" ]; then
  echo "Accepting Android SDK licenses..."
  yes | "$SDKMANAGER" --licenses >/dev/null || true
else
  echo "cmdline-tools not found at: $SDKMANAGER"
  echo "Install Android command-line tools to avoid release build failures."
fi

echo "Building release APK..."
"$FLUTTER_BIN" build apk --release

echo "Building release AAB..."
"$FLUTTER_BIN" build appbundle --release

echo "Done. Artifacts:"
echo "- $PROJECT_DIR/build/app/outputs/flutter-apk/app-release.apk"
echo "- $PROJECT_DIR/build/app/outputs/bundle/release/app-release.aab"
