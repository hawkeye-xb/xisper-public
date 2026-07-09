#!/bin/bash

# Sync secrets from .dev.vars to Cloudflare Workers
# Usage: ./scripts/sync-secrets-from-dev-vars.sh [env]
# env: (empty for default), beta, production

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Environment
ENV=${1:-""}
ENV_FLAG=""
if [ -n "$ENV" ]; then
    ENV_FLAG="--env $ENV"
    echo -e "${GREEN}Target environment: $ENV${NC}"
else
    echo -e "${GREEN}Target environment: default (development)${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Sync Secrets to Cloudflare Workers${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if .dev.vars exists
if [ ! -f ".dev.vars" ]; then
    echo -e "${RED}Error: .dev.vars file not found${NC}"
    exit 1
fi

# Source .dev.vars
source .dev.vars

echo -e "${YELLOW}Secrets to be synced:${NC}"
echo "  1. LOGTO_ENDPOINT"
echo "  2. LOGTO_APP_ID"
echo "  3. DEEPSEEK_API_KEY"
echo "  4. DOUBAO_APP_ID"
echo "  5. DOUBAO_ACCESS_TOKEN"
echo "  6. R2_ACCESS_KEY_ID"
echo "  7. R2_SECRET_ACCESS_KEY"
echo ""

# Confirm
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cancelled${NC}"
    exit 0
fi

echo ""

# Function to set secret
set_secret() {
    local name=$1
    local value=$2
    
    if [ -n "$value" ]; then
        echo -e "${GREEN}Setting $name...${NC}"
        echo "$value" | wrangler secret put "$name" $ENV_FLAG
    else
        echo -e "${YELLOW}Skipping $name (empty value)${NC}"
    fi
}

# Set secrets
set_secret "LOGTO_ENDPOINT" "$LOGTO_ENDPOINT"
set_secret "LOGTO_APP_ID" "$LOGTO_APP_ID"
set_secret "DEEPSEEK_API_KEY" "$DEEPSEEK_API_KEY"
set_secret "DOUBAO_APP_ID" "$DOUBAO_APP_ID"
set_secret "DOUBAO_ACCESS_TOKEN" "$DOUBAO_ACCESS_TOKEN"
set_secret "R2_ACCESS_KEY_ID" "$R2_ACCESS_KEY_ID"
set_secret "R2_SECRET_ACCESS_KEY" "$R2_SECRET_ACCESS_KEY"

# Optional secrets (only if not empty)
if [ -n "$LOGTO_APP_SECRET" ]; then
    set_secret "LOGTO_APP_SECRET" "$LOGTO_APP_SECRET"
fi

if [ -n "$OPENAI_API_KEY" ]; then
    set_secret "OPENAI_API_KEY" "$OPENAI_API_KEY"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Secrets synced successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# List secrets to verify
echo -e "${YELLOW}Verifying secrets:${NC}"
wrangler secret list $ENV_FLAG

echo ""
