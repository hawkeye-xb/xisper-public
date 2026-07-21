#!/bin/bash

# Cloudflare resource check script
# Purpose: quickly view all created resources
# Usage: ./scripts/cf-check-resources.sh

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare resource check${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}[1/5] Account info${NC}"
wrangler whoami
echo ""

echo -e "${BLUE}[2/5] KV namespaces${NC}"
wrangler kv namespace list
echo ""

echo -e "${BLUE}[3/5] D1 databases${NC}"
wrangler d1 list
echo ""

echo -e "${BLUE}[4/5] R2 buckets${NC}"
wrangler r2 bucket list
echo ""

echo -e "${BLUE}[5/5] Workers deployment history${NC}"
wrangler deployments list
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Resource check complete${NC}"
echo -e "${GREEN}========================================${NC}"
