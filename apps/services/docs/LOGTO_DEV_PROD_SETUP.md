# Logto Dev/Prod Environment Setup

Tenant: `fn2daz.logto.app` (shared endpoint, different appId per env)

## 1. xisper-dev Application (App ID: 2mepw39zb3jt55dnht427)

**Used for**: Beta env + local development (DV)

Logto Console → Applications → xisper-dev → 端点和凭据

### Redirect URIs (必填)
```
https://xisper-dev.hawkeye-xb.com/auth/desktop/callback
https://xisper-admin-beta.pages.dev/callback
http://localhost:8787/auth/desktop/callback
http://localhost:7010/callback
```
*If admin uses custom domain, add `https://<admin-beta-domain>/callback`*

### Post sign-out redirect URIs
```
https://xisper-dev.hawkeye-xb.com/auth/desktop/logout-complete
http://localhost:8787/auth/desktop/logout-complete
```

### CORS allowed origins
```
https://xisper-dev.hawkeye-xb.com
https://xisper-admin-beta.pages.dev
http://localhost:8787
http://localhost:7010
```

---

## 2. xisper-prod Application (App ID: vnd5x8k6zuotvpfm4o5tc)

Logto Console → Applications → xisper-prod → 端点和凭据

### Redirect URIs (必填)
```
https://xisper.hawkeye-xb.com/auth/desktop/callback
https://xisper-admin.pages.dev/callback
```
*If admin uses custom domain, add `https://<admin-prod-domain>/callback`*

### Post sign-out redirect URIs
```
https://xisper.hawkeye-xb.com/auth/desktop/logout-complete
```

### CORS allowed origins
```
https://xisper.hawkeye-xb.com
https://xisper-admin.pages.dev
```

---

## 3. Wrangler Secrets (apps/services)

```bash
cd apps/services

# Beta
wrangler secret put LOGTO_ENDPOINT --env beta
# Input: https://fn2daz.logto.app

wrangler secret put LOGTO_APP_ID --env beta
# Input: 2mepw39zb3jt55dnht427

# Production
wrangler secret put LOGTO_ENDPOINT --env production
# Input: https://fn2daz.logto.app

wrangler secret put LOGTO_APP_ID --env production
# Input: vnd5x8k6zuotvpfm4o5tc
```

---

## 4. Admin Build Env (optional, for CI/CD)

If admin build needs explicit Logto vars:
- Beta: `VITE_LOGTO_ENDPOINT=https://fn2daz.logto.app` `VITE_LOGTO_APP_ID=2mepw39zb3jt55dnht427`
- Prod: `VITE_LOGTO_ENDPOINT=https://fn2daz.logto.app` `VITE_LOGTO_APP_ID=vnd5x8k6zuotvpfm4o5tc`

Admin `config.ts` already has these hardcoded, so usually not needed.

---

## 5. Redeploy Commands (after secrets + Logto Console config)

Run from repo root. Order: services first (API), then admin (frontend). Execute one by one.

```
1. cd apps/services && pnpm deploy:beta && cd ../..

2. cd apps/services && pnpm deploy:prod && cd ../..

3. cd apps/admin && pnpm deploy:beta && cd ../..

4. cd apps/admin && pnpm deploy:prod && cd ../..
```
