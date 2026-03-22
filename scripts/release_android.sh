#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/release/android"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

echo "[1/4] Getting dependencies"
flutter pub get

echo "[2/4] Building Android App Bundle"
flutter build appbundle --release

echo "[3/4] Preparing release folder"
mkdir -p "$OUTPUT_DIR"

SRC_AAB="$ROOT_DIR/build/app/outputs/bundle/release/app-release.aab"
DST_AAB="$OUTPUT_DIR/taqyimdz-$TIMESTAMP.aab"

if [[ ! -f "$SRC_AAB" ]]; then
  echo "Release bundle not found: $SRC_AAB"
  exit 1
fi

cp "$SRC_AAB" "$DST_AAB"

echo "[4/4] Done"
echo "Release bundle: $DST_AAB"
