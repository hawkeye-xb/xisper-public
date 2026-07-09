#!/bin/bash

# Cloudflare Workers 密钥设置脚本
# 用途：批量设置项目所需的密钥
# 使用方法：./scripts/cf-setup-secrets.sh [dev|staging|prod]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认环境为空（默认环境）
ENV=${1:-""}
ENV_FLAG=""
if [ -n "$ENV" ] && [ "$ENV" != "dev" ]; then
    ENV_FLAG="--env $ENV"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare Workers 密钥设置${NC}"
if [ -n "$ENV" ]; then
    echo -e "${GREEN}目标环境: $ENV${NC}"
else
    echo -e "${GREEN}目标环境: development (默认)${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""

echo -e "${YELLOW}需要设置的密钥列表：${NC}"
echo "  1. LOGTO_ENDPOINT - Logto 服务端点"
echo "  2. LOGTO_APP_ID - Logto 应用 ID"
echo "  3. LOGTO_APP_SECRET - Logto 应用密钥"
echo "  4. OPENAI_API_KEY - OpenAI API 密钥"
echo "  5. DEEPSEEK_API_KEY - DeepSeek API 密钥 (可选)"
echo "  6. PAYMENT_WEBHOOK_SECRET - 支付 Webhook 密钥 (可选)"
echo ""
read -p "是否继续设置? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}操作已取消${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[1/6] 设置 LOGTO_ENDPOINT${NC}"
wrangler secret put LOGTO_ENDPOINT $ENV_FLAG

echo ""
echo -e "${GREEN}[2/6] 设置 LOGTO_APP_ID${NC}"
wrangler secret put LOGTO_APP_ID $ENV_FLAG

echo ""
echo -e "${GREEN}[3/6] 设置 LOGTO_APP_SECRET${NC}"
wrangler secret put LOGTO_APP_SECRET $ENV_FLAG

echo ""
echo -e "${GREEN}[4/6] 设置 OPENAI_API_KEY${NC}"
wrangler secret put OPENAI_API_KEY $ENV_FLAG

echo ""
echo -e "${YELLOW}[5/6] 设置 DEEPSEEK_API_KEY (可选，按 Ctrl+C 跳过)${NC}"
wrangler secret put DEEPSEEK_API_KEY $ENV_FLAG || echo -e "${YELLOW}已跳过${NC}"

echo ""
echo -e "${YELLOW}[6/6] 设置 PAYMENT_WEBHOOK_SECRET (可选，按 Ctrl+C 跳过)${NC}"
wrangler secret put PAYMENT_WEBHOOK_SECRET $ENV_FLAG || echo -e "${YELLOW}已跳过${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 密钥设置完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}查看已设置的密钥：${NC}"
wrangler secret list $ENV_FLAG
echo ""
