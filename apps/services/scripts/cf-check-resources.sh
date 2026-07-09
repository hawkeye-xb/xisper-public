#!/bin/bash

# Cloudflare 资源检查脚本
# 用途：快速查看所有已创建的资源
# 使用方法：./scripts/cf-check-resources.sh

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare 资源检查${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${BLUE}[1/5] 账号信息${NC}"
wrangler whoami
echo ""

echo -e "${BLUE}[2/5] KV 命名空间${NC}"
wrangler kv namespace list
echo ""

echo -e "${BLUE}[3/5] D1 数据库${NC}"
wrangler d1 list
echo ""

echo -e "${BLUE}[4/5] R2 存储桶${NC}"
wrangler r2 bucket list
echo ""

echo -e "${BLUE}[5/5] Workers 部署历史${NC}"
wrangler deployments list
echo ""

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 资源检查完成${NC}"
echo -e "${GREEN}========================================${NC}"
