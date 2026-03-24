#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FLUTTER_BIN=""
if [ -x "/mnt/shared/YBSAPP/flutter/bin/flutter" ]; then
  FLUTTER_BIN="/mnt/shared/YBSAPP/flutter/bin/flutter"
elif [ -x "/home/misters/flutter/bin/flutter" ]; then
  FLUTTER_BIN="/home/misters/flutter/bin/flutter"
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(command -v flutter)"
else
  echo "Flutter binary not found. Install Flutter or update this script."
  exit 1
fi

RUN_AFTER_CLEANUP=0
if [ "${1:-}" = "--run" ]; then
  RUN_AFTER_CLEANUP=1
  shift || true
fi

echo "Project: ${PROJECT_DIR}"
echo "Flutter: ${FLUTTER_BIN}"

echo "Stopping Gradle and Kotlin daemons..."
if [ -x "${PROJECT_DIR}/android/gradlew" ]; then
  "${PROJECT_DIR}/android/gradlew" --stop || true
fi
pkill -f kotlin-daemon || true
pkill -f GradleDaemon || true

echo "Removing locked Flutter tools Gradle build cache..."
rm -rf "/home/misters/flutter/packages/flutter_tools/gradle/build" || true
rm -rf "/mnt/shared/YBSAPP/flutter/packages/flutter_tools/gradle/build" || true

echo "Removing project Gradle and build caches..."
rm -rf "${PROJECT_DIR}/.gradle"
rm -rf "${PROJECT_DIR}/android/.gradle"
rm -rf "${PROJECT_DIR}/build"

echo "Running flutter clean + pub get..."
"${FLUTTER_BIN}" clean --project-dir "${PROJECT_DIR}"
"${FLUTTER_BIN}" pub get --project-dir "${PROJECT_DIR}"

if [ "${RUN_AFTER_CLEANUP}" -eq 1 ]; then
  echo "Running flutter run..."
  "${FLUTTER_BIN}" run --project-dir "${PROJECT_DIR}" "$@"
else
  echo "Done. You can now run:"
  echo "  ${FLUTTER_BIN} run --project-dir ${PROJECT_DIR}"
  echo "Or one-shot next time:"
  echo "  ./fix_gradle_lock.sh --run"
fi
