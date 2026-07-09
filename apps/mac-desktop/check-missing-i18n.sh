#!/bin/bash

# Script to check which hardcoded strings are actually missing from Localizable.xcstrings

XCSTRINGS="apps/mac-desktop/Xisper/Localizable.xcstrings"

# List of strings that appear to be hardcoded in the Swift files
STRINGS=(
    "Speaking Time"
    "Characters"
    "Import"
    "Export"
    "Identity"
    "Account"
    "Duration"
    "Raw Chars"
    "Speed"
    "Mode"
    "Audio"
    "Copy"
    "Copied"
    "Today"
    "Yesterday"
    "Dictation"
    "Translate"
    "ASK"
    "Ready"
    "Finalizing…"
    "Processing…"
    "Recording…"
    "Unlimited"
    "No usage limits"
    "Failed to read file"
    "Invalid CSV file"
    "Exported successfully"
    "All words already exist or invalid"
    "Failed to clear hotwords"
    "Retry transcription"
    "ASR service error — tap retry to re-transcribe"
    "(No content)"
    "Retranscribing..."
    "Retry Transcription"
    "Show in Finder"
)

echo "=== Checking Missing i18n Strings ==="
echo ""

MISSING=()
FOUND=()

for str in "${STRINGS[@]}"; do
    if grep -q "\"$str\"" "$XCSTRINGS"; then
        FOUND+=("$str")
    else
        MISSING+=("$str")
    fi
done

echo "✅ FOUND (${#FOUND[@]}):"
for str in "${FOUND[@]}"; do
    echo "  - $str"
done

echo ""
echo "❌ MISSING (${#MISSING[@]}):"
for str in "${MISSING[@]}"; do
    echo "  - $str"
done

echo ""
echo "=== Summary ==="
echo "Total checked: ${#STRINGS[@]}"
echo "Found: ${#FOUND[@]}"
echo "Missing: ${#MISSING[@]}"
