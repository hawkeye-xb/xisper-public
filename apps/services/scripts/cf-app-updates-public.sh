#!/usr/bin/env bash
# Configure production app update endpoints: Access bypass (public) + WAF rate limit (anti-abuse).
# Requires: CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_ZONE_ID
#   API token: Cloudflare Dashboard -> My Profile -> API Tokens (need Zone WAF Write, Account Access Read/Edit).
#   Account ID: Dashboard -> any zone -> Overview (right column).
#   Zone ID: Dashboard -> zone for xisper.hawkeye-xb.com (e.g. hawkeye-xb.com) -> Overview.
# Usage: CLOUDFLARE_ACCOUNT_ID=xxx CLOUDFLARE_ZONE_ID=yyy ./scripts/cf-app-updates-public.sh [production]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ENV=${1:-production}
BASE_URL="https://api.cloudflare.com/client/v4"

# Production: xisper.hawkeye-xb.com
DOMAIN="xisper.hawkeye-xb.com"
UPDATES_PATH="/api/app/updates"
# Rate limit: 60 req/min per IP (industry standard for public read-only); block 10 min when exceeded
RATE_PERIOD=60
RATE_REQUESTS=60
RATE_MITIGATION=600

if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
  echo -e "${RED}Error: CLOUDFLARE_API_TOKEN is required${NC}"
  exit 1
fi
if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
  echo -e "${RED}Error: CLOUDFLARE_ACCOUNT_ID is required (Zero Trust / Access)${NC}"
  exit 1
fi
if [ -z "$CLOUDFLARE_ZONE_ID" ]; then
  echo -e "${RED}Error: CLOUDFLARE_ZONE_ID is required (WAF rate limiting)${NC}"
  exit 1
fi

echo -e "${GREEN}=== App updates public + rate limit (${ENV}) ===${NC}"
echo "  Domain: ${DOMAIN}"
echo "  Path:   ${UPDATES_PATH} (bypass Access, then rate limit 60/min per IP)"
echo ""

# --- 1) Access: ensure an application exists for this path with Bypass policy ---
# Domain+path: matches /api/app/updates, /api/app/updates/manifest, /api/app/updates/download
APP_DOMAIN="${DOMAIN}${UPDATES_PATH}"
echo -e "${GREEN}[1/2] Access: bypass for ${APP_DOMAIN}${NC}"
LIST=$(curl -sS -X GET "${BASE_URL}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json")
EXISTING=$(echo "$LIST" | jq -r --arg d "$APP_DOMAIN" '.result[] | select(.domain == $d) | .id' 2>/dev/null || true)
if [ -n "$EXISTING" ]; then
  echo "  Access app already exists (id: $EXISTING). Skipping create."
else
  BODY=$(jq -n \
    --arg domain "$APP_DOMAIN" \
    --arg name "Xisper App Updates (Public)" \
    '{
      type: "self_hosted",
      name: $name,
      domain: $domain,
      self_hosted_domains: [$domain],
      policies: [{
        name: "Bypass (public)",
        decision: "bypass",
        include: [{ everyone: {} }],
        precedence: 1
      }]
    }')
  CREATE=$(curl -sS -X POST "${BASE_URL}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" -d "$BODY")
  if ! echo "$CREATE" | jq -e '.success' >/dev/null 2>&1; then
    echo -e "${RED}  Access app create failed:${NC}"
    echo "$CREATE" | jq .
    exit 1
  fi
  echo "  Created Access app (bypass for ${APP_DOMAIN})."
fi

# --- 2) WAF: add rate limit rule for /api/app/updates (zone http_ratelimit) ---
echo -e "${GREEN}[2/2] WAF: rate limit for ${UPDATES_PATH}* (${RATE_REQUESTS} req/${RATE_PERIOD}s per IP, block ${RATE_MITIGATION}s)${NC}"
ENTRY=$(curl -sS -X GET "${BASE_URL}/zones/${CLOUDFLARE_ZONE_ID}/rulesets/phases/http_ratelimit/entrypoint" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
RULESET_ID=$(echo "$ENTRY" | jq -r '.result.id // empty')
if [ -z "$RULESET_ID" ]; then
  # Create zone entry point ruleset for http_ratelimit with one rule
  CREATE_RS=$(curl -sS -X POST "${BASE_URL}/zones/${CLOUDFLARE_ZONE_ID}/rulesets" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    -d "{
      \"name\": \"Zone rate limit\",
      \"kind\": \"zone\",
      \"phase\": \"http_ratelimit\",
      \"rules\": [{
        \"description\": \"App updates: 60/min per IP\",
        \"expression\": \"(http.request.uri.path contains \\\"${UPDATES_PATH}\\\")\",
        \"action\": \"block\",
        \"ratelimit\": {
          \"characteristics\": [\"cf.colo.id\", \"ip.src\"],
          \"period\": ${RATE_PERIOD},
          \"requests_per_period\": ${RATE_REQUESTS},
          \"mitigation_timeout\": ${RATE_MITIGATION}
        }
      }]
    }")
  if ! echo "$CREATE_RS" | jq -e '.success' >/dev/null 2>&1; then
    echo -e "${RED}  Create http_ratelimit ruleset failed:${NC}"
    echo "$CREATE_RS" | jq .
    exit 1
  fi
  echo "  Created http_ratelimit ruleset and added rule."
else
  # Add rule to existing ruleset (rate limit rules must be at the end)
  RULE_BODY=$(jq -n \
    --arg path "$UPDATES_PATH" \
    --argjson period "$RATE_PERIOD" \
    --argjson requests "$RATE_REQUESTS" \
    --argjson mitigation "$RATE_MITIGATION" \
    '{
      description: "App updates: 60/min per IP",
      expression: ("(http.request.uri.path contains \"" + $path + "\")"),
      action: "block",
      ratelimit: {
        characteristics: ["cf.colo.id", "ip.src"],
        period: $period,
        requests_per_period: $requests,
        mitigation_timeout: $mitigation
      }
    }')
  ADD_RULE=$(curl -sS -X POST "${BASE_URL}/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${RULESET_ID}/rules" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" -d "$RULE_BODY")
  if ! echo "$ADD_RULE" | jq -e '.success' >/dev/null 2>&1; then
    echo -e "${RED}  Add rate limit rule failed (may already exist):${NC}"
    echo "$ADD_RULE" | jq .
    exit 1
  fi
  echo "  Added rate limit rule to existing ruleset."
fi

echo ""
echo -e "${GREEN}Done.${NC} Verify:"
echo "  curl -sI \"https://${DOMAIN}/api/app/updates/manifest?channel=production&platform=darwin\""
echo "  curl -sI \"https://${DOMAIN}/api/app/updates/download?channel=production&platform=darwin\""
