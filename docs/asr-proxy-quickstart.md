# ASR Proxy Quick Start

## Quick Test (3 minutes)

### 1. Setup Backend Credentials

```bash
cd apps/services

# Copy example file and fill in your credentials
cp .dev.vars.example .dev.vars

# Edit .dev.vars and add your Doubao credentials:
# DOUBAO_APP_ID=your-app-id
# DOUBAO_ACCESS_TOKEN=your-token
# DOUBAO_RESOURCE_ID=volc.bigasr.sauc.duration
```

### 2. Start Services

Terminal 1 - Backend:
```bash
cd apps/services
pnpm dev
```

Wait for: `⎔ Starting local server...`

Terminal 2 - Frontend:
```bash
cd apps/web
pnpm dev
```

### 3. Test Recording

1. Open application (browser or Electron)
2. Make sure you're logged in (JWT required)
3. Click record button
4. Speak something
5. Check Terminal 1 for logs:
   ```
   [ASR Proxy] Connecting to Doubao ASR...
   [ASR Proxy] Connected to Doubao ASR
   [ASR Proxy] Client -> ASR: 3200 bytes
   [ASR Response] {"code":20000000,"result":{"text":"你好"...}}
   ```

### 4. Test Heartbeat (30 seconds)

1. Start recording but stay silent
2. Wait 30+ seconds
3. Check logs for:
   ```
   [ASR Proxy] Sending heartbeat (idle for 30s)
   ```
4. Speak again - should still work

## Troubleshooting

### "Missing authentication token"
- Make sure you're logged in
- Check browser console for JWT token errors
- Try logout and login again

### "ASR service not configured"
- Backend is missing Doubao credentials
- Check `.env` file or run `wrangler secret list`

### No audio transmitted
- Check microphone permissions
- Check browser/Electron audio permissions
- Look for errors in frontend console

### Connection timeout
- Backend not running on port 8787
- Check for port conflicts
- Try `lsof -i :8787` to verify

## What Changed?

### Before
```
Frontend -> Direct WebSocket -> Doubao ASR
  (App ID and Token in frontend config)
```

### After
```
Frontend -> Worker Proxy -> Doubao ASR
  (JWT Auth)     (Credentials)
```

### Key Changes

1. **Frontend Config** (`apps/web/src/config/recording-config.ts`)
   - URL changed to: `ws://localhost:8787/api/v1/asr/proxy`
   - JWT token added to connection

2. **Backend Service** (`apps/services/src/routes/asr-proxy.ts`)
   - New WebSocket proxy endpoint
   - Handles authentication
   - Forwards audio bidirectionally
   - 30-second heartbeat
   - Logs all responses

3. **Environment Variables**
   - Backend: `DOUBAO_APP_ID`, `DOUBAO_ACCESS_TOKEN`
   - Frontend: `VITE_ASR_PROXY_URL`

## Rollback

If you need to rollback to direct connection:

1. **Revert frontend config:**
   ```typescript
   // apps/web/src/config/recording-config.ts
   URL: 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async'
   ```

2. **Revert ws-manager.ts:**
   ```typescript
   // Uncomment original buildWebSocketUrl code
   url.searchParams.append('api_app_key', config.appid)
   url.searchParams.append('api_access_key', config.token)
   ```

3. **Restart frontend**

## Production Deployment

See [asr-proxy-setup.md](./asr-proxy-setup.md) for complete deployment guide.

Quick commands:

```bash
# Set production secrets
wrangler secret put DOUBAO_APP_ID --env production
wrangler secret put DOUBAO_ACCESS_TOKEN --env production

# Deploy backend
cd apps/services
wrangler deploy --env production

# Update frontend env
# VITE_ASR_PROXY_URL=wss://xisper.hawkeye-xb.com/api/v1/asr/proxy

# Deploy frontend
cd apps/web
pnpm build
# ... your deployment process
```

## Next Steps

1. ✅ Test locally with recordings
2. ✅ Verify heartbeat works (30s silence test)
3. ✅ Check logs show ASR responses
4. 📋 Deploy to staging/production
5. 📋 Monitor for a few days
6. 📋 Remove old credentials from frontend (optional)

## Support

- Full setup guide: [asr-proxy-setup.md](./asr-proxy-setup.md)
- Backend logs: Check terminal running `pnpm dev`
- Frontend logs: Browser/Electron DevTools console
- Production logs: `wrangler tail --env production`
