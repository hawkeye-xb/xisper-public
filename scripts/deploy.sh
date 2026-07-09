#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Xisper — Unified Deploy Script (Local Release)
# ─────────────────────────────────────────────────────────────────────
# Captures git metadata, generates deploy-info.ts, runs wrangler deploy,
# and logs the deployment to a local history file for traceability.
#
# Usage:
#   bash scripts/deploy.sh <app> <env>
#
# Examples:
#   bash scripts/deploy.sh services beta
#   bash scripts/deploy.sh services production
#   bash scripts/deploy.sh ai-worker beta
#   bash scripts/deploy.sh ai-worker production
#   bash scripts/deploy.sh all beta          # deploy both services + ai-worker
# ─────────────────────────────────────────────────────────────────────

set -euo pipefail

APP="${1:-}"
ENV="${2:-}"
VALID_APPS="services ai-worker all"
VALID_ENVS="beta production"

if [ -z "$APP" ] || [ -z "$ENV" ]; then
  echo "Usage: bash scripts/deploy.sh <services|ai-worker|all> <beta|production>"
  exit 1
fi

if ! echo "$VALID_APPS" | grep -qw "$APP"; then
  echo "ERROR: Invalid app '$APP'. Must be one of: $VALID_APPS"
  exit 1
fi

if ! echo "$VALID_ENVS" | grep -qw "$ENV"; then
  echo "ERROR: Invalid env '$ENV'. Must be one of: $VALID_ENVS"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOY_LOG="$ROOT_DIR/.deploy-history.log"

# ── Git metadata ─────────────────────────────────────────────────────
GIT_HASH=$(git -C "$ROOT_DIR" rev-parse HEAD)
GIT_SHORT=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
GIT_BRANCH=$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)
GIT_DIRTY=$(git -C "$ROOT_DIR" diff --quiet && echo "false" || echo "true")
GIT_MSG=$(git -C "$ROOT_DIR" log -1 --pretty=format:'%s' | head -c 120)
DEPLOY_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DEPLOYER=$(git -C "$ROOT_DIR" config user.name 2>/dev/null || whoami)

# ── Safety check: warn if working tree is dirty ──────────────────────
if [ "$GIT_DIRTY" = "true" ]; then
  echo ""
  echo "⚠️  Working tree has uncommitted changes!"
  echo "   Deploy will record the HEAD commit ($GIT_SHORT) but actual code may differ."
  echo ""
  if [ "$ENV" = "production" ]; then
    read -p "Continue deploying dirty tree to PRODUCTION? (y/N): " -r
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
fi

# ── Production double-confirm ────────────────────────────────────────
if [ "$ENV" = "production" ]; then
  echo ""
  echo "🔴 PRODUCTION deployment: $APP"
  echo "   Commit: $GIT_SHORT ($GIT_BRANCH)"
  echo "   Message: $GIT_MSG"
  echo ""
  read -p "Type 'DEPLOY' to confirm: " -r
  if [ "$REPLY" != "DEPLOY" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Generate deploy-info.ts ──────────────────────────────────────────
generate_deploy_info() {
  local app_dir="$1"
  local app_name="$2"
  local gen_dir="$app_dir/src/generated"
  mkdir -p "$gen_dir"

  cat > "$gen_dir/deploy-info.ts" << TSEOF
export const DEPLOY_INFO = {
  gitHash: '${GIT_HASH}',
  gitShort: '${GIT_SHORT}',
  gitBranch: '${GIT_BRANCH}',
  gitDirty: ${GIT_DIRTY},
  gitMessage: '${GIT_MSG//\'/\\\'}',
  deployTime: '${DEPLOY_TIME}',
  deployer: '${DEPLOYER}',
  app: '${app_name}',
  env: '${ENV}',
} as const;
TSEOF

  echo "  ✓ Generated $gen_dir/deploy-info.ts"
}

# ── Deploy a single app ──────────────────────────────────────────────
deploy_app() {
  local app_name="$1"
  local app_dir="$ROOT_DIR/apps/$app_name"

  if [ ! -d "$app_dir" ]; then
    echo "ERROR: App directory not found: $app_dir"
    exit 1
  fi

  echo ""
  echo "══════════════════════════════════════════════"
  echo "  Deploying: $app_name → $ENV"
  echo "  Commit:    $GIT_SHORT ($GIT_BRANCH)${GIT_DIRTY:+ [dirty]}"
  echo "  Message:   $GIT_MSG"
  echo "  Time:      $DEPLOY_TIME"
  echo "  Deployer:  $DEPLOYER"
  echo "══════════════════════════════════════════════"
  echo ""

  generate_deploy_info "$app_dir" "$app_name"

  echo "  → Running wrangler deploy --env $ENV ..."
  echo ""
  cd "$app_dir"
  npx wrangler deploy --env "$ENV"

  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo ""
    echo "❌ Deploy FAILED for $app_name → $ENV"
    log_deploy "$app_name" "FAILED"
    return $exit_code
  fi

  echo ""
  echo "✅ $app_name deployed to $ENV"
  log_deploy "$app_name" "SUCCESS"
}

# ── Append to local deploy history ───────────────────────────────────
log_deploy() {
  local app_name="$1"
  local status="$2"

  echo "[$DEPLOY_TIME] $status | $app_name → $ENV | $GIT_SHORT ($GIT_BRANCH)${GIT_DIRTY:+ [dirty]} | $GIT_MSG | by $DEPLOYER" >> "$DEPLOY_LOG"
}

# ── Execute ──────────────────────────────────────────────────────────
if [ "$APP" = "all" ]; then
  deploy_app "services"
  deploy_app "ai-worker"
else
  deploy_app "$APP"
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════"
echo "  DEPLOY COMPLETE"
echo "══════════════════════════════════════════════"
echo ""
echo "  Verify via API:"
if [ "$ENV" = "beta" ]; then
  echo "    curl https://xisper-dev.hawkeye-xb.com/api/v1/health"
  echo "    curl https://xisper-dev.hawkeye-xb.com/api/v1/info"
else
  echo "    curl https://xisper.hawkeye-xb.com/api/v1/health"
  echo "    curl https://xisper.hawkeye-xb.com/api/v1/info"
fi
echo ""
echo "  Local deploy log: $DEPLOY_LOG"
echo ""
echo "══════════════════════════════════════════════"
