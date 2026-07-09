#!/bin/bash

# Cloudflare Workers 部署脚本
# 用途：标准化部署流程，包含安全检查
# 使用方法：./scripts/cf-deploy.sh [dev|staging|prod]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认环境为 development
ENV=${1:-dev}
ENV_FLAG=""
if [ "$ENV" != "dev" ]; then
    ENV_FLAG="--env $ENV"
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cloudflare Workers 部署流程${NC}"
echo -e "${GREEN}目标环境: $ENV${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 生产环境额外确认
if [ "$ENV" = "prod" ]; then
    echo -e "${RED}⚠️  警告：即将部署到生产环境！${NC}"
    echo ""
    read -p "确认要部署到生产环境吗? 输入 'DEPLOY' 继续: " -r
    echo ""
    if [ "$REPLY" != "DEPLOY" ]; then
        echo -e "${YELLOW}部署已取消${NC}"
        exit 0
    fi
fi

# 步骤 1: 运行测试（如果存在）
if [ -f "package.json" ] && grep -q "\"test\"" package.json; then
    echo -e "${GREEN}[1/4] 运行测试...${NC}"
    npm test || {
        echo -e "${RED}测试失败，部署已中止${NC}"
        exit 1
    }
else
    echo -e "${YELLOW}[1/4] 未找到测试脚本，跳过${NC}"
fi

# 步骤 2: 构建项目（如果存在构建脚本）
if [ -f "package.json" ] && grep -q "\"build\"" package.json; then
    echo ""
    echo -e "${GREEN}[2/4] 构建项目...${NC}"
    npm run build
else
    echo ""
    echo -e "${YELLOW}[2/4] 未找到构建脚本，跳过${NC}"
fi

# 步骤 3: 空运行检查（仅生产环境）
if [ "$ENV" = "prod" ]; then
    echo ""
    echo -e "${GREEN}[3/4] 执行部署预检...${NC}"
    wrangler deploy $ENV_FLAG --dry-run
else
    echo ""
    echo -e "${YELLOW}[3/4] 跳过部署预检（非生产环境）${NC}"
fi

# 步骤 4: 实际部署
echo ""
echo -e "${GREEN}[4/4] 开始部署...${NC}"
wrangler deploy $ENV_FLAG

# 部署成功
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 部署成功！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}后续操作：${NC}"
echo "  - 查看实时日志: ${GREEN}wrangler tail $ENV_FLAG${NC}"
echo "  - 查看部署历史: ${GREEN}wrangler deployments list $ENV_FLAG${NC}"
if [ "$ENV" = "prod" ]; then
    echo "  - 访问控制台: https://dash.cloudflare.com"
fi
echo ""
