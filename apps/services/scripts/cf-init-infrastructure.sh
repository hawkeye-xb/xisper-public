#!/bin/bash

# Cloudflare 基础设施初始化脚本
# 用途：一键创建 KV、D1、R2 资源
# 使用方法：./scripts/cf-init-infrastructure.sh [dev|staging|prod]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认环境为 development
ENV=${1:-dev}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare 基础设施初始化${NC}"
echo -e "${GREEN}目标环境: $ENV${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查 wrangler 是否安装
if ! command -v npx &> /dev/null; then
    echo -e "${RED}错误: 未找到 npx 命令，请先安装 Node.js${NC}"
    exit 1
fi

# 确认操作
echo -e "${YELLOW}即将创建以下资源：${NC}"
echo "  - KV 命名空间 (AI_KV)"
echo "  - D1 数据库 (ai-services-db-$ENV)"
echo "  - R2 存储桶 (ai-services-files-$ENV)"
echo ""
read -p "是否继续? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}操作已取消${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[1/6] 创建 KV 命名空间...${NC}"
if [ "$ENV" = "dev" ]; then
    wrangler kv namespace create AI_KV
    wrangler kv namespace create AI_KV --preview
else
    wrangler kv namespace create AI_KV --env $ENV
    wrangler kv namespace create AI_KV --env $ENV --preview
fi

echo ""
echo -e "${GREEN}[2/6] 创建 D1 数据库...${NC}"
wrangler d1 create ai-services-db-$ENV

echo ""
echo -e "${GREEN}[3/6] 创建 R2 存储桶...${NC}"
wrangler r2 bucket create ai-services-files-$ENV

if [ "$ENV" = "dev" ]; then
    echo ""
    echo -e "${GREEN}[4/6] 创建预览用 R2 存储桶...${NC}"
    wrangler r2 bucket create ai-services-files-preview || echo -e "${YELLOW}预览存储桶可能已存在${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 基础设施创建完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}下一步操作：${NC}"
echo "1. 将上述输出的 ID 复制到 wrangler.toml 配置文件中"
echo "2. 运行 ${GREEN}./scripts/cf-init-db.sh $ENV${NC} 初始化数据库结构"
echo "3. 运行 ${GREEN}./scripts/cf-setup-secrets.sh $ENV${NC} 设置密钥"
echo "4. 前往 Cloudflare 控制台手动配置 R2 生命周期规则"
echo ""
echo -e "${YELLOW}R2 生命周期规则配置：${NC}"
echo "  - 前往: https://dash.cloudflare.com → R2 → ai-services-files-$ENV"
echo "  - 设置规则: Prefix=temp/, Action=Delete after 1 day"
echo ""
