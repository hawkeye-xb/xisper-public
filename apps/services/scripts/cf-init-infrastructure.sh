#!/bin/bash

# Cloudflare infrastructure initialization script
# Purpose: create KV, D1, and R2 resources in one shot
# Usage: ./scripts/cf-init-infrastructure.sh [dev|staging|prod]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default environment is development
ENV=${1:-dev}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare infrastructure initialization${NC}"
echo -e "${GREEN}Target environment: $ENV${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check whether wrangler is installed
if ! command -v npx &> /dev/null; then
    echo -e "${RED}Error: npx not found; please install Node.js first${NC}"
    exit 1
fi

# Confirm the operation
echo -e "${YELLOW}About to create the following resources:${NC}"
echo "  - KV namespace (AI_KV)"
echo "  - D1 database (ai-services-db-$ENV)"
echo "  - R2 bucket (ai-services-files-$ENV)"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[1/6] Creating KV namespace...${NC}"
if [ "$ENV" = "dev" ]; then
    wrangler kv namespace create AI_KV
    wrangler kv namespace create AI_KV --preview
else
    wrangler kv namespace create AI_KV --env $ENV
    wrangler kv namespace create AI_KV --env $ENV --preview
fi

echo ""
echo -e "${GREEN}[2/6] Creating D1 database...${NC}"
wrangler d1 create ai-services-db-$ENV

echo ""
echo -e "${GREEN}[3/6] Creating R2 bucket...${NC}"
wrangler r2 bucket create ai-services-files-$ENV

if [ "$ENV" = "dev" ]; then
    echo ""
    echo -e "${GREEN}[4/6] Creating preview R2 bucket...${NC}"
    wrangler r2 bucket create ai-services-files-preview || echo -e "${YELLOW}Preview bucket may already exist${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Infrastructure created!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Copy the IDs printed above into the wrangler.toml configuration file"
echo "2. Run ${GREEN}./scripts/cf-init-db.sh $ENV${NC} to initialize the database schema"
echo "3. Run ${GREEN}./scripts/cf-setup-secrets.sh $ENV${NC} to set secrets"
echo "4. Go to the Cloudflare dashboard to configure R2 lifecycle rules manually"
echo ""
echo -e "${YELLOW}R2 lifecycle rule configuration:${NC}"
echo "  - Go to: https://dash.cloudflare.com → R2 → ai-services-files-$ENV"
echo "  - Set rule: Prefix=temp/, Action=Delete after 1 day"
echo ""
