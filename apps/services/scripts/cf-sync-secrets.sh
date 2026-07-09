#!/bin/bash

# Cloudflare Workers Secret Sync Script
# Purpose: Sync secrets from local environment file to Cloudflare Workers
# Usage: ./scripts/cf-sync-secrets.sh [production|staging] [--dry-run] [--key KEY_NAME]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
ENVIRONMENT=""
DRY_RUN=false
SPECIFIC_KEY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        production|staging|dev)
            ENVIRONMENT=$1
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --key)
            SPECIFIC_KEY="$2"
            shift 2
            ;;
        --help|-h)
            echo "Cloudflare Workers Secret Sync Script"
            echo ""
            echo "Usage: ./scripts/cf-sync-secrets.sh [ENVIRONMENT] [OPTIONS]"
            echo ""
            echo "Environments:"
            echo "  production    Sync secrets from .env.production (default)"
            echo "  staging       Sync secrets from .env.staging"
            echo "  dev           Sync secrets from .dev.vars"
            echo ""
            echo "Options:"
            echo "  --dry-run     Preview changes without actually syncing"
            echo "  --key NAME    Sync only a specific key"
            echo "  --help, -h    Show this help message"
            echo ""
            echo "Examples:"
            echo "  ./scripts/cf-sync-secrets.sh production"
            echo "  ./scripts/cf-sync-secrets.sh production --dry-run"
            echo "  ./scripts/cf-sync-secrets.sh production --key OPENAI_API_KEY"
            echo "  ./scripts/cf-sync-secrets.sh staging"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Usage: ./scripts/cf-sync-secrets.sh [production|staging|dev] [--dry-run] [--key KEY_NAME]"
            echo "Run with --help for more information"
            exit 1
            ;;
    esac
done

# Default to production if not specified
if [ -z "$ENVIRONMENT" ]; then
    ENVIRONMENT="production"
fi

# Determine environment file
if [ "$ENVIRONMENT" = "dev" ]; then
    ENV_FILE=".dev.vars"
else
    ENV_FILE=".env.${ENVIRONMENT}"
fi

# Determine wrangler env flag
ENV_FLAG=""
if [ "$ENVIRONMENT" != "dev" ]; then
    ENV_FLAG="--env $ENVIRONMENT"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare Workers Secret Sync${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Environment: ${ENVIRONMENT}${NC}"
echo -e "${BLUE}Config file: ${ENV_FILE}${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Mode: DRY RUN (no actual changes)${NC}"
else
    echo -e "${BLUE}Mode: LIVE SYNC${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if environment file exists
if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: Environment file ${ENV_FILE} not found!${NC}"
    echo -e "${YELLOW}Please create it from the example file:${NC}"
    echo -e "  cp ${ENV_FILE}.example ${ENV_FILE}"
    echo -e "  # Then edit ${ENV_FILE} with your actual values"
    exit 1
fi

# Check if wrangler is installed
if ! command -v wrangler &> /dev/null; then
    echo -e "${RED}Error: wrangler CLI is not installed!${NC}"
    echo -e "${YELLOW}Install it with: npm install -g wrangler${NC}"
    exit 1
fi

# Function to parse env file and get all keys
get_env_keys() {
    grep -v '^#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | grep '=' | cut -d '=' -f 1
}

# Function to get value for a specific key
get_env_value() {
    local key=$1
    grep "^${key}=" "$ENV_FILE" | cut -d '=' -f 2- | sed 's/^["'"'"']//' | sed 's/["'"'"']$//'
}

# Function to sync a single secret
sync_secret() {
    local key=$1
    local value=$2
    
    if [ -z "$value" ]; then
        echo -e "${YELLOW}  ⊘ Skipping ${key} (empty value)${NC}"
        return
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}  ✓ Would sync ${key}${NC}"
    else
        echo -e "${GREEN}  ↑ Syncing ${key}...${NC}"
        echo "$value" | wrangler secret put "$key" $ENV_FLAG > /dev/null 2>&1
        echo -e "${GREEN}  ✓ ${key} synced successfully${NC}"
    fi
}

# Main sync logic
if [ -n "$SPECIFIC_KEY" ]; then
    # Sync specific key
    echo -e "${BLUE}Syncing specific key: ${SPECIFIC_KEY}${NC}"
    echo ""
    
    value=$(get_env_value "$SPECIFIC_KEY")
    if [ -z "$value" ]; then
        echo -e "${RED}Error: Key ${SPECIFIC_KEY} not found or has empty value in ${ENV_FILE}${NC}"
        exit 1
    fi
    
    sync_secret "$SPECIFIC_KEY" "$value"
else
    # Sync all keys
    echo -e "${BLUE}Reading secrets from ${ENV_FILE}...${NC}"
    echo ""
    
    keys=$(get_env_keys)
    total_keys=$(echo "$keys" | wc -l | tr -d ' ')
    current=0
    
    echo -e "${BLUE}Found ${total_keys} secrets to sync:${NC}"
    echo "$keys" | while IFS= read -r line; do
        echo "  - $line"
    done
    echo ""
    
    if [ "$DRY_RUN" = false ]; then
        read -p "Continue with sync? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Operation cancelled${NC}"
            exit 0
        fi
        echo ""
    fi
    
    # Sync each secret
    echo -e "${BLUE}Syncing secrets...${NC}"
    echo ""
    
    while IFS= read -r key; do
        current=$((current + 1))
        value=$(get_env_value "$key")
        echo -e "${BLUE}[${current}/${total_keys}] ${key}${NC}"
        sync_secret "$key" "$value"
        echo ""
    done <<< "$keys"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}✓ Dry run completed!${NC}"
    echo -e "${YELLOW}Run without --dry-run to actually sync${NC}"
else
    echo -e "${GREEN}✓ Secrets synced successfully!${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

# Show current secrets list
if [ "$DRY_RUN" = false ]; then
    echo -e "${BLUE}Current secrets in Cloudflare:${NC}"
    wrangler secret list $ENV_FLAG
    echo ""
fi

echo -e "${YELLOW}Useful commands:${NC}"
echo -e "  ${BLUE}# List all secrets${NC}"
echo -e "  wrangler secret list $ENV_FLAG"
echo ""
echo -e "  ${BLUE}# Delete a secret${NC}"
echo -e "  wrangler secret delete SECRET_NAME $ENV_FLAG"
echo ""
echo -e "  ${BLUE}# Sync a specific key${NC}"
echo -e "  ./scripts/cf-sync-secrets.sh $ENVIRONMENT --key KEY_NAME"
echo ""
