#!/bin/bash
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJ_DIR/.build"

echo "▶ Killing existing Xisper instance..."
pkill -x Xisper 2>/dev/null || true
sleep 0.3

echo "▶ Building..."
xcodebuild \
  -project "$PROJ_DIR/Xisper.xcodeproj" \
  -scheme Xisper \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  BUILD_DIR="$BUILD_DIR" \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED|Compiling"

echo "▶ Launching..."
open "$BUILD_DIR/Debug/Xisper.app"
echo "✓ Done — app is running"
