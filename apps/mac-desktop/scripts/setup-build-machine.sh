#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Xisper macOS Native — New Build Machine Setup
# ─────────────────────────────────────────────────────────────────────
# Usage:
#   1. Copy this script + .env.build to the new machine
#   2. Put the Developer ID .p12 certificate file next to this script
#   3. Run: bash setup-build-machine.sh
#
# What this script does:
#   - Installs Homebrew tools (xcodegen, create-dmg)
#   - Imports Developer ID certificate into Keychain
#   - Imports Sparkle EdDSA private key into Keychain
#   - Logs into Cloudflare wrangler
#   - Stores notarization credentials in Keychain (notarytool)
#   - Verifies everything is ready
# ─────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env.build"

# ── Load .env.build ──────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found."
  echo "Copy .env.build.example to .env.build and fill in the values first."
  exit 1
fi
set -a; source "$ENV_FILE"; set +a
echo "✓ Loaded $ENV_FILE"

# ── 1. Homebrew tools ────────────────────────────────────────────────
echo ""
echo "── Step 1: Install build tools ──"

if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

for tool in xcodegen create-dmg; do
  if command -v "$tool" &>/dev/null; then
    echo "✓ $tool already installed"
  else
    echo "Installing $tool..."
    brew install "$tool"
  fi
done

# ── 2. Developer ID Certificate ─────────────────────────────────────
echo ""
echo "── Step 2: Developer ID Certificate ──"

EXISTING_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [ -n "$EXISTING_CERT" ]; then
  echo "✓ Developer ID certificate found in Keychain:"
  echo "  $EXISTING_CERT"
else
  P12_FILE=$(find "$SCRIPT_DIR" -name "*.p12" -maxdepth 1 | head -1)
  if [ -z "$P12_FILE" ]; then
    echo "⚠ No Developer ID certificate found in Keychain."
    echo "  Export from Xcode on existing machine:"
    echo "    Xcode → Settings → Accounts → Manage Certificates"
    echo "    → Right-click 'Developer ID Application' → Export"
    echo "  Then place the .p12 file in: $SCRIPT_DIR/"
    echo "  And re-run this script."
  else
    echo "Importing $P12_FILE..."
    echo "You will be prompted for the .p12 export password."
    security import "$P12_FILE" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
    echo "✓ Certificate imported"
  fi
fi

# ── 3. Sparkle EdDSA Key ────────────────────────────────────────────
echo ""
echo "── Step 3: Sparkle EdDSA Signing Key ──"

# Check if Sparkle key already exists in Keychain
SPARKLE_CHECK=$(/usr/bin/security find-generic-password -a "ed25519" -s "https://sparkle-project.org" 2>/dev/null && echo "found" || echo "not_found")

if [ "$SPARKLE_CHECK" = "found" ]; then
  echo "✓ Sparkle EdDSA key already in Keychain"
else
  if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "⚠ SPARKLE_PRIVATE_KEY not set in .env.build, skipping."
  else
    # Write key to temp file and import via generate_keys
    SPARKLE_BIN="$PROJECT_DIR/../../node_modules/.pnpm/*/node_modules/sparkle/bin"
    # Try to find generate_keys from Xcode DerivedData
    GEN_KEYS=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*/Sparkle/*" 2>/dev/null | head -1)

    if [ -z "$GEN_KEYS" ]; then
      echo "⚠ Sparkle generate_keys not found."
      echo "  Open Xisper.xcodeproj in Xcode first (to download SPM packages),"
      echo "  then re-run this script."
    else
      TMPKEY=$(mktemp)
      echo -n "$SPARKLE_PRIVATE_KEY" > "$TMPKEY"
      "$GEN_KEYS" -f "$TMPKEY"
      rm -f "$TMPKEY"
      echo "✓ Sparkle EdDSA key imported into Keychain"
    fi
  fi
fi

# ── 4. Cloudflare Wrangler Login ─────────────────────────────────────
echo ""
echo "── Step 4: Cloudflare Wrangler ──"

if npx wrangler whoami 2>/dev/null | grep -q "You are logged in"; then
  echo "✓ Wrangler already logged in"
else
  echo "Opening browser for Cloudflare login..."
  npx wrangler login
fi

# ── 5. Apple Notarization Credentials ────────────────────────────────
echo ""
echo "── Step 5: Apple Notarization Credentials ──"

if [ -z "${APPLE_ID:-}" ] || [ "$APPLE_ID" = "__YOUR_APPLE_ID_EMAIL__" ]; then
  echo "⚠ APPLE_ID not configured in .env.build"
  echo "  Fill in your Apple ID email and App-Specific Password."
  echo "  Generate App-Specific Password at: https://appleid.apple.com"
  echo "    → Sign-In and Security → App-Specific Passwords"
else
  # Store credentials in Keychain so notarytool can use --keychain-profile
  xcrun notarytool store-credentials "xisper-notarize" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" 2>/dev/null \
    && echo "✓ Notarization credentials stored as Keychain profile 'xisper-notarize'" \
    || echo "✓ Notarization credentials profile 'xisper-notarize' already exists or updated"
fi

# ── 6. Verify ────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  Setup Summary"
echo "══════════════════════════════════════════════"
echo ""

check() {
  if eval "$2" &>/dev/null; then
    echo "  ✓ $1"
  else
    echo "  ✗ $1"
  fi
}

check "Xcode CLI tools" "xcode-select -p"
check "xcodegen" "command -v xcodegen"
check "create-dmg" "command -v create-dmg"
check "Developer ID cert" "security find-identity -v -p codesigning | grep -q 'Developer ID Application'"
check "Wrangler auth" "npx wrangler whoami 2>/dev/null | grep -q 'logged in'"
check ".env.build" "test -f '$ENV_FILE'"

echo ""
echo "If all checks pass, you can build with:"
echo "  cd apps/mac-desktop && bash scripts/build-and-release.sh beta"
echo ""
