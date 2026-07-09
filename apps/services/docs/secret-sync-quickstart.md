# 🚀 Secret Sync Quick Start

Quick reference for syncing environment variables to Cloudflare Workers.

---

## ⚡️ 3-Step Setup

```bash
# 1. Create production config
cp .env.production.example .env.production

# 2. Edit with your keys
nano .env.production

# 3. Sync to Cloudflare
./scripts/cf-sync-secrets.sh production
```

---

## 📋 Keys Checklist

Prepare these keys before starting:

- [ ] **LOGTO_ENDPOINT** - Get from [Logto Console](https://logto.io)
- [ ] **LOGTO_APP_ID** - Get from Logto Console → Your App
- [ ] **LOGTO_APP_SECRET** - Get from Logto Console (optional for SPA)
- [ ] **OPENAI_API_KEY** - Get from [OpenAI Platform](https://platform.openai.com/api-keys)
- [ ] **DEEPSEEK_API_KEY** (Optional) - Get from [DeepSeek Platform](https://platform.deepseek.com)
- [ ] **PAYMENT_WEBHOOK_SECRET** (Optional) - From your payment provider

---

## 🎯 Common Commands

```bash
# Preview before sync
./scripts/cf-sync-secrets.sh production --dry-run

# Sync all secrets
./scripts/cf-sync-secrets.sh production

# Sync single key
./scripts/cf-sync-secrets.sh production --key OPENAI_API_KEY

# Check synced secrets
wrangler secret list --env production

# Get help
./scripts/cf-sync-secrets.sh --help
```

---

## 🔄 Deployment Flow

```bash
# Setup → Sync → Deploy
cp .env.production.example .env.production
./scripts/cf-sync-secrets.sh production
wrangler deploy --env production
```

---

## 📖 Full Documentation

See [Secret Management Guide](./secret-management.md) for detailed documentation.

---

**Pro Tip**: Always use `--dry-run` first to preview changes!
