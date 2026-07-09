#!/bin/bash

# Cloudflare D1 数据库初始化脚本
# 用途：执行数据库 schema 文件
# 使用方法：./scripts/cf-init-db.sh [dev|staging|prod]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认环境为 development
ENV=${1:-dev}
DB_NAME="ai-services-db-$ENV"
SCHEMA_FILE="./database/schema.sql"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}D1 数据库初始化${NC}"
echo -e "${GREEN}目标数据库: $DB_NAME${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查 schema 文件是否存在
if [ ! -f "$SCHEMA_FILE" ]; then
    echo -e "${RED}错误: 找不到 schema 文件: $SCHEMA_FILE${NC}"
    echo -e "${YELLOW}提示: 请先创建数据库 schema 文件${NC}"
    exit 1
fi

# 确认操作
echo -e "${YELLOW}即将执行以下操作：${NC}"
echo "  - 数据库: $DB_NAME"
echo "  - Schema 文件: $SCHEMA_FILE"
echo ""
read -p "是否继续? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}操作已取消${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}正在执行数据库初始化...${NC}"
wrangler d1 execute $DB_NAME --remote --file=$SCHEMA_FILE

echo ""
echo -e "${GREEN}✅ 数据库初始化完成！${NC}"
echo ""
echo -e "${YELLOW}验证数据库：${NC}"
wrangler d1 execute $DB_NAME --remote --command="SELECT name FROM sqlite_master WHERE type='table';"
echo ""
