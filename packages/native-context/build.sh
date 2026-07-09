#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building libXisperContext.dylib..."
swift build -c release

# Copy the built dylib to the package root for easy access
BUILT_LIB=$(find .build -name "libXisperContext.dylib" -not -path "*dSYM*" -type f | head -1)
if [ -z "$BUILT_LIB" ]; then
  echo "ERROR: libXisperContext.dylib not found in .build/release"
  exit 1
fi

cp "$BUILT_LIB" ./libXisperContext.dylib
echo "Built: $(pwd)/libXisperContext.dylib"

# Also copy Swift runtime dependencies if not system-provided
echo "Done."
