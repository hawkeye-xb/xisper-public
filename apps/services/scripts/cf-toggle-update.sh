#!/bin/bash

# Cloudflare App Update Toggle Script
# Purpose: Enable or disable app auto-updates
# Usage: ./scripts/cf-toggle-update.sh [channel] [enabled] [mandatory] [env]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
CHANNEL=${1:-production}
ENABLED=${2:-true}
MANDATORY=${3:-false}
ENV_OVERRIDE=${4:-}

# Environment: MUST match channel for isolation (beta KV for beta, prod KV for prod)
# Override with 4th arg only for local dev (e.g. ENV=dev to skip)
if [ -n "$ENV_OVERRIDE" ]; then
    ENV="$ENV_OVERRIDE"
else
    ENV="$CHANNEL"
fi

ENV_FLAG=""
if [ -n "$ENV" ] && [ "$ENV" != "dev" ]; then
    ENV_FLAG="--env $ENV"
fi

# Show help
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo -e "${GREEN}Cloudflare App Update Toggle Script${NC}"
    echo ""
    echo "Usage: ./scripts/cf-toggle-update.sh [CHANNEL] [ENABLED] [MANDATORY] [ENV]"
    echo ""
    echo "Arguments:"
    echo "  CHANNEL     Update channel: beta | production (default: production)"
    echo "  ENABLED     Enable updates: true | false (default: true)"
    echo "  MANDATORY   Force update: true | false (default: false)"
    echo "  ENV         Override env (default: same as CHANNEL for isolation)"
    echo ""
    echo "Examples:"
    echo "  # Enable production channel updates (non-mandatory)"
    echo "  ./scripts/cf-toggle-update.sh production true false"
    echo ""
    echo "  # Enable beta channel with mandatory update"
    echo "  ./scripts/cf-toggle-update.sh beta true true"
    echo ""
    echo "  # Disable production channel updates"
    echo "  ./scripts/cf-toggle-update.sh production false false"
    echo ""
    echo "  # Override env (e.g. for local dev)"
    echo "  ./scripts/cf-toggle-update.sh beta true false dev"
    echo ""
    echo "Quick commands:"
    echo "  # Enable production updates"
    echo "  ./scripts/cf-toggle-update.sh production true"
    echo ""
    echo "  # Disable production updates"
    echo "  ./scripts/cf-toggle-update.sh production false"
    echo ""
    echo "  # Enable mandatory update (emergency)"
    echo "  ./scripts/cf-toggle-update.sh production true true"
    exit 0
fi

# Validate parameters
if [ "$CHANNEL" != "beta" ] && [ "$CHANNEL" != "production" ]; then
    echo -e "${RED}Error: CHANNEL must be 'beta' or 'production'${NC}"
    exit 1
fi

if [ "$ENABLED" != "true" ] && [ "$ENABLED" != "false" ]; then
    echo -e "${RED}Error: ENABLED must be 'true' or 'false'${NC}"
    exit 1
fi

if [ "$MANDATORY" != "true" ] && [ "$MANDATORY" != "false" ]; then
    echo -e "${RED}Error: MANDATORY must be 'true' or 'false'${NC}"
    exit 1
fi

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo -e "${RED}Error: wrangler CLI not found${NC}"
    echo -e "${YELLOW}Install with: npm install -g wrangler${NC}"
    exit 1
fi

# Show current configuration
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}App Update Configuration${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Channel:      ${CHANNEL}${NC}"
echo -e "${BLUE}Enabled:      ${ENABLED}${NC}"
echo -e "${BLUE}Mandatory:    ${MANDATORY}${NC}"
if [ -n "$ENV" ]; then
    echo -e "${BLUE}Environment:  ${ENV}${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

# Confirm operation with appropriate warning
if [ "$ENABLED" = "true" ]; then
    echo -e "${YELLOW}⚠️  About to ENABLE auto-updates for ${CHANNEL} channel${NC}"
    if [ "$MANDATORY" = "true" ]; then
        echo -e "${RED}⚠️  WARNING: This is a MANDATORY update!${NC}"
        echo -e "${RED}    All users will be REQUIRED to upgrade!${NC}"
    else
        echo -e "${YELLOW}    Users will be notified and can choose to update${NC}"
    fi
else
    echo -e "${YELLOW}About to DISABLE auto-updates for ${CHANNEL} channel${NC}"
    echo -e "${YELLOW}Users will not receive update notifications${NC}"
fi
echo ""
read -p "Confirm? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

# Build config JSON
CONFIG_JSON="{\"enabled\":$ENABLED,\"mandatory\":$MANDATORY}"

# Update KV configuration
echo ""
echo -e "${BLUE}Updating configuration...${NC}"
wrangler kv key put $ENV_FLAG \
  --binding=APP_UPDATE_CONFIG \
  --preview false \
  "update_config:$CHANNEL" \
  "$CONFIG_JSON"

echo -e "${GREEN}✅ Configuration updated successfully!${NC}"
echo ""

# Show current all configurations
echo -e "${BLUE}Current update configurations:${NC}"
wrangler kv key list $ENV_FLAG --binding=APP_UPDATE_CONFIG --preview false

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Operation completed${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Generate test command
if [ "$CHANNEL" = "beta" ]; then
    API_URL="https://xisper-dev.hawkeye-xb.com"
elif [ "$CHANNEL" = "production" ]; then
    API_URL="https://xisper.hawkeye-xb.com"
else
    API_URL="http://localhost:8787"
fi

echo -e "${YELLOW}💡 Test update detection:${NC}"
echo -e "  ${GREEN}curl \"$API_URL/api/app/updates/manifest?channel=$CHANNEL&platform=darwin\"${NC}"
echo ""

# Show quick toggle commands
echo -e "${YELLOW}💡 Quick commands:${NC}"
echo -e "  ${BLUE}# View current config${NC}"
echo -e "  ${GREEN}wrangler kv key get $ENV_FLAG --binding=APP_UPDATE_CONFIG --preview false \"update_config:$CHANNEL\"${NC}"
echo ""
echo -e "  ${BLUE}# Disable updates${NC}"
echo -e "  ${GREEN}./scripts/cf-toggle-update.sh $CHANNEL false${NC}"
echo ""
echo -e "  ${BLUE}# Enable updates${NC}"
echo -e "  ${GREEN}./scripts/cf-toggle-update.sh $CHANNEL true${NC}"
echo ""
