# Secret Management Guide

This guide explains how to manage environment variables and secrets for Cloudflare Workers deployment.

---

## 📁 File Structure

```
apps/services/
├── .dev.vars                    # Local development (not committed)
├── .dev.vars.example            # Template for local development
├── .env.production              # Production config (not committed)
└── .env.production.example      # Template for production
```

---

## 🔑 Required Keys

You need to prepare the following API keys and credentials:

### Required Keys

| Key | Description | Where to Get | Required For |
|-----|-------------|--------------|--------------|
| `LOGTO_ENDPOINT` | Logto authentication endpoint | [Logto Console](https://logto.io) | Authentication |
| `LOGTO_APP_ID` | Logto application ID | Logto Console → Your App | Authentication |
| `LOGTO_APP_SECRET` | Logto application secret | Logto Console → Your App | Authentication (optional for SPA) |
| `OPENAI_API_KEY` | OpenAI API key | [OpenAI Platform](https://platform.openai.com) | AI features |

### Optional Keys

| Key | Description | Where to Get | Required For |
|-----|-------------|--------------|--------------|
| `DEEPSEEK_API_KEY` | DeepSeek AI API key | [DeepSeek Platform](https://platform.deepseek.com) | Alternative AI provider |
| `PAYMENT_WEBHOOK_SECRET` | Payment webhook secret | Your payment provider | Payment integration |

---

## 🚀 Quick Setup

### Step 1: Setup Local Development

```bash
# Copy template
cp .dev.vars.example .dev.vars

# Edit with your development keys
nano .dev.vars  # or use your preferred editor
```

### Step 2: Setup Production Environment

```bash
# Copy template
cp .env.production.example .env.production

# Edit with your production keys
nano .env.production
```

**Example `.env.production` file:**

```bash
LOGTO_ENDPOINT=https://your-prod-tenant.logto.app
LOGTO_APP_ID=your-production-app-id
LOGTO_APP_SECRET=your-production-secret
OPENAI_API_KEY=sk-prod-xxxxxxxxxxxxx
DEEPSEEK_API_KEY=sk-prod-xxxxxxxxxxxxx
PAYMENT_WEBHOOK_SECRET=whsec_prod_xxxxx
```

### Step 3: Sync to Cloudflare

```bash
# Preview what will be synced (dry run)
./scripts/cf-sync-secrets.sh production --dry-run

# Sync all secrets to production
./scripts/cf-sync-secrets.sh production

# Sync a specific key only
./scripts/cf-sync-secrets.sh production --key OPENAI_API_KEY
```

---

## 📖 Usage Examples

### Sync to Different Environments

```bash
# Sync to production
./scripts/cf-sync-secrets.sh production

# Sync to staging
./scripts/cf-sync-secrets.sh staging

# Sync to development (uses .dev.vars)
./scripts/cf-sync-secrets.sh dev
```

### Sync Specific Keys

```bash
# Update only OpenAI key
./scripts/cf-sync-secrets.sh production --key OPENAI_API_KEY

# Update only Logto endpoint
./scripts/cf-sync-secrets.sh production --key LOGTO_ENDPOINT
```

### Dry Run (Preview Changes)

```bash
# See what would be synced without actually doing it
./scripts/cf-sync-secrets.sh production --dry-run
```

### Verify Synced Secrets

```bash
# List all secrets in production
wrangler secret list --env production

# List secrets in staging
wrangler secret list --env staging
```

### Delete a Secret

```bash
# Delete a specific secret
wrangler secret delete DEEPSEEK_API_KEY --env production
```

---

## 🔒 Security Best Practices

### ✅ DO

- ✅ Use different keys for development and production
- ✅ Keep `.env.production` in `.gitignore`
- ✅ Use `--dry-run` to preview changes before syncing
- ✅ Rotate keys regularly
- ✅ Use minimal permissions for each API key
- ✅ Share only the `.example` files in git

### ❌ DON'T

- ❌ Never commit `.dev.vars` or `.env.production` to git
- ❌ Never share production keys in Slack/email
- ❌ Never use production keys in local development
- ❌ Never hardcode secrets in source code
- ❌ Never log secrets in console/logs

---

## 🔄 Deployment Workflow

### First Time Deployment

```bash
# 1. Setup production config
cp .env.production.example .env.production
# Edit .env.production with your production keys

# 2. Sync secrets to Cloudflare
./scripts/cf-sync-secrets.sh production

# 3. Verify secrets are synced
wrangler secret list --env production

# 4. Deploy
wrangler deploy --env production
```

### Updating Secrets

```bash
# 1. Update your .env.production file
nano .env.production

# 2. Sync the specific changed key
./scripts/cf-sync-secrets.sh production --key OPENAI_API_KEY

# 3. Restart workers (automatic after secret update)
```

---

## 🆚 Script Comparison

| Feature | `cf-setup-secrets.sh` | `cf-sync-secrets.sh` |
|---------|----------------------|----------------------|
| **Input Method** | Interactive prompts | Read from file |
| **Use Case** | First-time setup | Regular updates |
| **Batch Support** | Yes (prompts for each) | Yes (auto-sync all) |
| **Dry Run** | No | Yes |
| **Single Key Update** | No | Yes |
| **Recommended For** | Manual setup | Automated workflow |

---

## 🐛 Troubleshooting

### Error: "Environment file not found"

```bash
# Solution: Create the environment file first
cp .env.production.example .env.production
# Then edit it with your keys
```

### Error: "wrangler CLI is not installed"

```bash
# Solution: Install wrangler globally
npm install -g wrangler
```

### Error: "Failed to sync secret"

```bash
# Solution: Check if you're logged in to Cloudflare
wrangler login

# Verify your account
wrangler whoami
```

### Secret not taking effect

```bash
# Solution: Secrets are applied immediately, but you can verify:
wrangler secret list --env production

# If needed, trigger a new deployment
wrangler deploy --env production
```

---

## 📚 Additional Resources

- [Cloudflare Workers Secrets Documentation](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Wrangler CLI Documentation](https://developers.cloudflare.com/workers/wrangler/)
- [Logto Documentation](https://docs.logto.io/)

---

**Last Updated**: 2026-02-02  
**Maintained by**: Xisper Team
