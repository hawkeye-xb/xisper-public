#!/bin/bash

# Cloudflare App Update System Initialization Script
# Purpose: Create KV Namespace and initialize update configuration
# Usage: ./scripts/cf-setup-auto-update.sh [dev|staging|prod]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default environment is development
ENV=${1:-dev}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}App Update System Initialization${NC}"
echo -e "${GREEN}Target environment: $ENV${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo -e "${RED}Error: wrangler CLI not found${NC}"
    echo -e "${YELLOW}Install with: npm install -g wrangler${NC}"
    exit 1
fi

# Confirm operation
echo -e "${YELLOW}The following resources will be created:${NC}"
echo "  - KV Namespace (APP_UPDATE_CONFIG)"
echo "  - Initialize update config (beta & production channels)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[1/3] Creating KV Namespace...${NC}"

# Create KV namespace based on environment
if [ "$ENV" = "dev" ]; then
    echo -e "${BLUE}  Creating namespace for development...${NC}"
    KV_OUTPUT=$(wrangler kv namespace create APP_UPDATE_CONFIG 2>&1 | tee /dev/tty)
    echo -e "${BLUE}  Creating preview namespace...${NC}"
    KV_PREVIEW_OUTPUT=$(wrangler kv namespace create APP_UPDATE_CONFIG --preview 2>&1 | tee /dev/tty)
else
    echo -e "${BLUE}  Creating namespace for $ENV environment...${NC}"
    KV_OUTPUT=$(wrangler kv namespace create APP_UPDATE_CONFIG --env $ENV 2>&1 | tee /dev/tty)
    KV_PREVIEW_OUTPUT=$(wrangler kv namespace create APP_UPDATE_CONFIG --env $ENV --preview 2>&1 | tee /dev/tty)
fi

# Extract KV Namespace IDs
KV_ID=$(echo "$KV_OUTPUT" | grep -o 'id = "[^"]*"' | head -1 | cut -d'"' -f2)
KV_PREVIEW_ID=$(echo "$KV_PREVIEW_OUTPUT" | grep -o 'id = "[^"]*"' | head -1 | cut -d'"' -f2)

if [ -z "$KV_ID" ]; then
    echo -e "${YELLOW}⚠️  KV Namespace may already exist, skipping creation${NC}"
    echo -e "${YELLOW}    If namespace doesn't exist, check wrangler output above${NC}"
else
    echo -e "${GREEN}✅ KV Namespace created successfully${NC}"
fi

echo ""
echo -e "${GREEN}[2/3] Initializing update configuration...${NC}"

# Determine environment flag for wrangler commands
if [ "$ENV" = "dev" ]; then
    ENV_FLAG=""
else
    ENV_FLAG="--env $ENV"
fi

# Initialize default config for beta channel
echo -e "${BLUE}  Initializing beta channel config...${NC}"
wrangler kv key put $ENV_FLAG \
  --binding=APP_UPDATE_CONFIG \
  --preview false \
  "update_config:beta" \
  '{"enabled":false,"mandatory":false}' \
  2>/dev/null || echo -e "${YELLOW}  ⚠️  May already exist${NC}"

# Initialize default config for production channel
echo -e "${BLUE}  Initializing production channel config...${NC}"
wrangler kv key put $ENV_FLAG \
  --binding=APP_UPDATE_CONFIG \
  --preview false \
  "update_config:production" \
  '{"enabled":false,"mandatory":false}' \
  2>/dev/null || echo -e "${YELLOW}  ⚠️  May already exist${NC}"

echo -e "${GREEN}✅ Update configuration initialized${NC}"

echo ""
echo -e "${GREEN}[3/3] Generating configuration output...${NC}"
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ App Update System Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}📋 Next steps:${NC}"
echo ""

# Step 1: Update wrangler.toml
echo -e "${BLUE}1. Update wrangler.toml configuration${NC}"
if [ -n "$KV_ID" ]; then
    echo "   Add the following to wrangler.toml:"
    echo ""
    if [ "$ENV" = "dev" ]; then
        echo "   [[kv_namespaces]]"
        echo "   binding = \"APP_UPDATE_CONFIG\""
        echo "   id = \"$KV_ID\""
        echo "   preview_id = \"$KV_PREVIEW_ID\""
    else
        echo "   [[env.$ENV.kv_namespaces]]"
        echo "   binding = \"APP_UPDATE_CONFIG\""
        echo "   id = \"$KV_ID\""
    fi
    echo ""
else
    echo "   KV Namespace may already be configured in wrangler.toml"
    echo "   If not, run this script again or check Cloudflare dashboard"
    echo ""
fi

# Step 2: Configure R2 environment variables
echo -e "${BLUE}2. Configure R2 environment variables${NC}"
echo "   Edit .dev.vars or .env.production:"
echo "   R2_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com"
echo "   R2_ACCESS_KEY_ID=your_access_key_id"
echo "   R2_SECRET_ACCESS_KEY=your_secret_access_key"
echo "   R2_BUCKET_NAME=xisper-releases"
echo "   R2_PUBLIC_URL=  # Optional, custom domain"
echo ""

# Step 3: Sync secrets
echo -e "${BLUE}3. Sync secrets to Cloudflare${NC}"
echo "   ${GREEN}./scripts/cf-sync-secrets.sh $ENV${NC}"
echo ""

# Step 4: Deploy
echo -e "${BLUE}4. Deploy services${NC}"
if [ "$ENV" = "dev" ]; then
    echo "   ${GREEN}wrangler deploy${NC}"
else
    echo "   ${GREEN}wrangler deploy --env $ENV${NC}"
fi
echo ""

# Step 5: Test
echo -e "${BLUE}5. Test update detection${NC}"
if [ "$ENV" = "dev" ]; then
    echo "   ${GREEN}curl \"http://localhost:8787/api/app/updates/manifest?channel=beta&platform=darwin\"${NC}"
else
    echo "   ${GREEN}curl \"https://xisper-dev.hawkeye-xb.com/api/app/updates/manifest?channel=beta&platform=darwin\"${NC}"
fi
echo ""

# Tips
echo -e "${YELLOW}💡 Useful tips:${NC}"
echo "  - Enable/disable updates: ${GREEN}./scripts/cf-toggle-update.sh${NC}"
echo "  - List KV keys: ${GREEN}wrangler kv key list $ENV_FLAG --binding=APP_UPDATE_CONFIG --preview false${NC}"
echo "  - View a specific config: ${GREEN}wrangler kv key get $ENV_FLAG --binding=APP_UPDATE_CONFIG --preview false \"update_config:beta\"${NC}"
echo ""
