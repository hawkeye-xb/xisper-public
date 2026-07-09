#!/bin/bash

set -e

# Change to mac-desktop directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAC_DESKTOP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$MAC_DESKTOP_DIR"

echo "🔧 Running Swift i18n translation..."
echo "Working directory: $(pwd)"
echo ""

# Load DEEPSEEK_API_KEY from .env file
if [ -f .env ]; then
  API_KEY=$(grep '^DEEPSEEK_API_KEY=' .env | cut -d '=' -f 2- | tr -d '"' | tr -d "'")
  if [ -n "$API_KEY" ]; then
    export DEEPSEEK_API_KEY="$API_KEY"
  fi
fi

# Execute translation script
node ../../packages/i18n-tools/src/translate-swift.js

echo ""
echo "✅ Translation complete!"
