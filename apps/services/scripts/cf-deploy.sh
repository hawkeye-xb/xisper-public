#!/bin/bash

# Cloudflare Workers deployment script
# Purpose: standardized deployment flow with safety checks
# Usage: ./scripts/cf-deploy.sh [dev|staging|prod]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default environment is development
ENV=${1:-dev}
ENV_FLAG=""
if [ "$ENV" != "dev" ]; then
    ENV_FLAG="--env $ENV"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare Workers deployment flow${NC}"
echo -e "${GREEN}Target environment: $ENV${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Extra confirmation for production
if [ "$ENV" = "prod" ]; then
    echo -e "${RED}⚠️  Warning: about to deploy to PRODUCTION!${NC}"
    echo ""
    read -p "Deploy to production? Type 'DEPLOY' to continue: " -r
    echo ""
    if [ "$REPLY" != "DEPLOY" ]; then
        echo -e "${YELLOW}Deployment cancelled${NC}"
        exit 0
    fi
fi

# Step 1: run tests (if present)
if [ -f "package.json" ] && grep -q "\"test\"" package.json; then
    echo -e "${GREEN}[1/4] Running tests...${NC}"
    npm test || {
        echo -e "${RED}Tests failed; deployment aborted${NC}"
        exit 1
    }
else
    echo -e "${YELLOW}[1/4] No test script found; skipping${NC}"
fi

# Step 2: build the project (if a build script exists)
if [ -f "package.json" ] && grep -q "\"build\"" package.json; then
    echo ""
    echo -e "${GREEN}[2/4] Building project...${NC}"
    npm run build
else
    echo ""
    echo -e "${YELLOW}[2/4] No build script found; skipping${NC}"
fi

# Step 3: dry-run check (production only)
if [ "$ENV" = "prod" ]; then
    echo ""
    echo -e "${GREEN}[3/4] Running deployment pre-check...${NC}"
    wrangler deploy $ENV_FLAG --dry-run
else
    echo ""
    echo -e "${YELLOW}[3/4] Skipping deployment pre-check (non-production)${NC}"
fi

# Step 4: actual deployment
echo ""
echo -e "${GREEN}[4/4] Deploying...${NC}"
wrangler deploy $ENV_FLAG

# Deployment succeeded
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Deployment successful!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Follow-up actions:${NC}"
echo "  - View live logs: ${GREEN}wrangler tail $ENV_FLAG${NC}"
echo "  - View deployment history: ${GREEN}wrangler deployments list $ENV_FLAG${NC}"
if [ "$ENV" = "prod" ]; then
    echo "  - Open dashboard: https://dash.cloudflare.com"
fi
echo ""
