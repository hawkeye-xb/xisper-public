#!/bin/bash

# Auto-update system test script
# For quickly verifying the system works correctly

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Auto Update System Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check whether the service is running
echo -e "${BLUE}[1/4] Checking if wrangler dev is running...${NC}"
if curl -s http://localhost:8787/health > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Service is running${NC}"
else
    echo -e "${YELLOW}⚠️  Service not running. Please start it with:${NC}"
    echo -e "   ${GREEN}cd apps/services && wrangler dev --port 8787${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}[2/4] Testing with updates DISABLED (default)...${NC}"
RESPONSE=$(curl -s -w "\n%{http_code}" "http://localhost:8787/api/app/updates/manifest?channel=beta&platform=darwin")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "204" ]; then
    echo -e "${GREEN}✅ Returns 204 No Content (updates disabled)${NC}"
elif [ "$HTTP_CODE" = "500" ]; then
    echo -e "${RED}❌ Error 500: $BODY${NC}"
    echo -e "${YELLOW}   This usually means wrangler dev needs restart after wrangler.toml changes${NC}"
    echo -e "${YELLOW}   Please restart: cd apps/services && wrangler dev --port 8787${NC}"
    exit 1
else
    echo -e "${YELLOW}⚠️  Unexpected status: $HTTP_CODE${NC}"
    echo "$BODY"
fi

echo ""
echo -e "${BLUE}[3/4] Enabling beta updates...${NC}"
./scripts/cf-toggle-update.sh beta true false > /dev/null 2>&1 << 'EOF'
y
EOF
echo -e "${GREEN}✅ Beta updates enabled${NC}"

echo ""
echo -e "${BLUE}[4/4] Testing with updates ENABLED...${NC}"
RESPONSE=$(curl -s -w "\n%{http_code}" "http://localhost:8787/api/app/updates/manifest?channel=beta&platform=darwin")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "204" ]; then
    echo -e "${GREEN}✅ Returns 204 No Content (enabled but no files in R2)${NC}"
    echo -e "${YELLOW}   This is expected - no actual release files yet${NC}"
elif [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ Returns 200 OK with manifest${NC}"
    echo "$BODY"
else
    echo -e "${YELLOW}⚠️  Unexpected status: $HTTP_CODE${NC}"
    echo "$BODY"
fi

echo ""
echo -e "${BLUE}Checking KV configuration...${NC}"
BETA_CONFIG=$(wrangler kv key get --binding=APP_UPDATE_CONFIG --preview false "update_config:beta" 2>/dev/null)
echo -e "${GREEN}Beta config: ${BETA_CONFIG}${NC}"

echo ""
echo -e "${BLUE}Disabling updates for cleanup...${NC}"
./scripts/cf-toggle-update.sh beta false false > /dev/null 2>&1 << 'EOF'
y
EOF
echo -e "${GREEN}✅ Updates disabled${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ Test Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}💡 Next steps:${NC}"
echo "  1. Read LOCAL_TESTING_GUIDE.md for detailed testing scenarios"
echo "  2. To test with mock files, follow 'Method B' in the guide"
echo "  3. When ready, push a real tag to test end-to-end"
echo ""
