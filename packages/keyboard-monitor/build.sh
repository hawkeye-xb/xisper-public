#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building libXisperKeyboard.dylib..."
swift build -c release

# SPM only compiles the library target to .o; it does not link a .dylib. Link it ourselves.
OBJ_DIR=$(find .build -type d -name "XisperKeyboard.build" -path "*release*" | head -1)
if [ -z "$OBJ_DIR" ]; then
  echo "ERROR: XisperKeyboard.build not found under .build"
  exit 1
fi
OBJS=("$OBJ_DIR"/*.o)
if [ ! -f "${OBJS[0]}" ]; then
  echo "ERROR: no .o files in $OBJ_DIR"
  exit 1
fi

clang -dynamiclib -o libXisperKeyboard.dylib "${OBJS[@]}" \
  -framework CoreGraphics -framework Carbon -framework AppKit \
  -install_name @rpath/libXisperKeyboard.dylib

echo "Built: $(pwd)/libXisperKeyboard.dylib"
echo "Done."
