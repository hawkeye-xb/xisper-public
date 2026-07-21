#!/bin/bash

# Cloudflare D1 database initialization script
# Purpose: runs the database schema file
# Usage: ./scripts/cf-init-db.sh [dev|staging|prod]

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default environment is development
ENV=${1:-dev}
DB_NAME="ai-services-db-$ENV"
SCHEMA_FILE="./database/schema.sql"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}D1 database initialization${NC}"
echo -e "${GREEN}Target database: $DB_NAME${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check whether the schema file exists
if [ ! -f "$SCHEMA_FILE" ]; then
    echo -e "${RED}Error: schema file not found: $SCHEMA_FILE${NC}"
    echo -e "${YELLOW}Hint: create the database schema file first${NC}"
    exit 1
fi

# Confirm the operation
echo -e "${YELLOW}About to perform the following:${NC}"
echo "  - Database: $DB_NAME"
echo "  - Schema file: $SCHEMA_FILE"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Operation cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Running database initialization...${NC}"
wrangler d1 execute $DB_NAME --remote --file=$SCHEMA_FILE

echo ""
echo -e "${GREEN}✅ Database initialization complete!${NC}"
echo ""
echo -e "${YELLOW}Verifying database:${NC}"
wrangler d1 execute $DB_NAME --remote --command="SELECT name FROM sqlite_master WHERE type='table';"
echo ""
