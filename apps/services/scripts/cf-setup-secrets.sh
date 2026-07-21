#!/bin/bash

# Cloudflare Workers secrets setup script
# Purpose: batch-set the secrets required by the project
# Usage: ./scripts/cf-setup-secrets.sh [dev|staging|prod]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default environment is empty (the default environment)
ENV=${1:-""}
ENV_FLAG=""
if [ -n "$ENV" ] && [ "$ENV" != "dev" ]; then
    ENV_FLAG="--env $ENV"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare Workers secrets setup${NC}"
if [ -n "$ENV" ]; then
    echo -e "${GREEN}Target environment: $ENV${NC}"
else
    echo -e "${GREEN}Target environment: development (default)${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}Secrets to set:${NC}"
echo "  1. LOGTO_ENDPOINT - Logto server endpoint"
echo "  2. LOGTO_APP_ID - Logto application ID"
echo "  3. LOGTO_APP_SECRET - Logto application secret"
echo "  4. OPENAI_API_KEY - OpenAI API key"
echo "  5. DEEPSEEK_API_KEY - DeepSeek API key (optional)"
echo "  6. PAYMENT_WEBHOOK_SECRET - Payment webhook secret (optional)"
echo ""
read -p "Continue with setup? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[1/6] Setting LOGTO_ENDPOINT${NC}"
wrangler secret put LOGTO_ENDPOINT $ENV_FLAG

echo ""
echo -e "${GREEN}[2/6] Setting LOGTO_APP_ID${NC}"
wrangler secret put LOGTO_APP_ID $ENV_FLAG

echo ""
echo -e "${GREEN}[3/6] Setting LOGTO_APP_SECRET${NC}"
wrangler secret put LOGTO_APP_SECRET $ENV_FLAG

echo ""
echo -e "${GREEN}[4/6] Setting OPENAI_API_KEY${NC}"
wrangler secret put OPENAI_API_KEY $ENV_FLAG

echo ""
echo -e "${YELLOW}[5/6] Setting DEEPSEEK_API_KEY (optional, Ctrl+C to skip)${NC}"
wrangler secret put DEEPSEEK_API_KEY $ENV_FLAG || echo -e "${YELLOW}Skipped${NC}"

echo ""
echo -e "${YELLOW}[6/6] Setting PAYMENT_WEBHOOK_SECRET (optional, Ctrl+C to skip)${NC}"
wrangler secret put PAYMENT_WEBHOOK_SECRET $ENV_FLAG || echo -e "${YELLOW}Skipped${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Secrets setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}View configured secrets:${NC}"
wrangler secret list $ENV_FLAG
echo ""
