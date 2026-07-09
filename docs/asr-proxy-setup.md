# ASR Proxy Setup Guide

## Overview

This guide covers the setup, testing, and deployment of the ASR proxy service that forwards WebSocket connections from the frontend to Doubao ASR service.

## Architecture

```
Frontend (Electron/Web) -> Worker Proxy -> Doubao ASR
```

The proxy service:
- Handles authentication via JWT tokens
- Forwards audio data bidirectionally
- Implements 30-second heartbeat mechanism
- Logs all ASR responses for debugging

## Local Development Setup

### 1. Backend Configuration

#### Set Environment Variables

For local development, edit `.dev.vars` file in `apps/services/`:

```bash
cd apps/services

# Copy example file if you haven't already
cp .dev.vars.example .dev.vars

# Edit .dev.vars and add your Doubao credentials
# The file should contain:
# DOUBAO_APP_ID=your-doubao-app-id
# DOUBAO_ACCESS_TOKEN=your-doubao-access-token
# DOUBAO_RESOURCE_ID=volc.bigasr.sauc.duration
# DOUBAO_CLUSTER=
```

Note: `.dev.vars` is gitignored and used by `wrangler dev` automatically.

#### Start Backend Service

```bash
cd apps/services
pnpm dev
```

The service will start on `http://localhost:8787`

### 2. Frontend Configuration

The frontend is configured to use `ws://localhost:8787/api/v1/asr/proxy` for development by default.

To change the URL (e.g., for production), edit `apps/web/src/config/recording-config.ts`:

```typescript
ws: {
  URL: 'wss://xisper.hawkeye-xb.com/api/v1/asr/proxy', // Change this for production
  // ...
}
```

#### Start Frontend Service

```bash
cd apps/web
pnpm dev
```

## Testing

### 1. Basic Connection Test

1. Start both backend and frontend services
2. Open the application in your browser or Electron
3. Ensure you are logged in (JWT token is required)
4. Try to start a recording
5. Check backend logs for:
   - `[ASR Proxy] Connecting to Doubao ASR...`
   - `[ASR Proxy] Connected to Doubao ASR`
   - `[ASR Proxy] Client -> ASR: X bytes`
   - `[ASR Response] ...`

### 2. Heartbeat Test

1. Start a recording connection
2. Stay silent for 30+ seconds
3. Check backend logs for:
   - `[ASR Proxy] Sending heartbeat (idle for 30s)`
4. Verify the connection remains active
5. Resume speaking and verify recognition continues

### 3. Error Handling Test

#### Invalid Token Test
```bash
# Try connecting without token (should fail with 401)
wscat -c "ws://localhost:8787/api/v1/asr/proxy"
```

Expected: Connection rejected with "Missing authentication token"

#### Network Interruption Test
1. Start recording
2. Temporarily disable network
3. Re-enable network
4. Verify connection recovers (may need to restart recording)

### 4. Load Test

Test with multiple concurrent connections:

```bash
# Run multiple recording sessions simultaneously
# Monitor backend logs for connection handling
```

Check:
- All connections are handled correctly
- No connection leaks
- Heartbeats work for all connections

## Production Deployment

### 1. Backend Deployment

#### Set Production Secrets

```bash
cd apps/services

# Set production secrets
wrangler secret put DOUBAO_APP_ID --env production
wrangler secret put DOUBAO_ACCESS_TOKEN --env production
wrangler secret put DOUBAO_RESOURCE_ID --env production
# DOUBAO_CLUSTER is optional
```

#### Deploy to Cloudflare Workers

```bash
# Build and deploy
pnpm build
wrangler deploy --env production
```

Verify deployment:
```bash
# Check deployment status
wrangler deployments list --env production
```

### 2. Frontend Configuration

Update WebSocket URL in `apps/web/src/config/recording-config.ts` for production:

```typescript
ws: {
  URL: 'wss://xisper.hawkeye-xb.com/api/v1/asr/proxy', // Production URL
  // ...
}
```

Build and deploy frontend:

```bash
cd apps/web
pnpm build
# Deploy according to your deployment strategy
```

### 3. Production Verification

1. **Test Basic Functionality**
   - Open production application
   - Login with valid account
   - Start recording
   - Verify transcription works

2. **Monitor Logs**
   ```bash
   # View real-time logs
   wrangler tail --env production
   ```

3. **Check Metrics**
   - Open Cloudflare Dashboard
   - Navigate to Workers & Pages
   - Check `xisper-services` worker
   - Monitor:
     - Request rate
     - Error rate
     - CPU time usage
     - WebSocket connections

### 4. Rollback Procedure

If issues occur in production:

```bash
# List recent deployments
wrangler deployments list --env production

# Rollback to previous version
wrangler rollback --env production --deployment-id <deployment-id>
```

## Monitoring and Debugging

### View Logs

#### Development
Backend logs are visible in the terminal running `pnpm dev`

#### Production
```bash
# Real-time logs
wrangler tail --env production

# Filter specific messages
wrangler tail --env production --format json | grep "ASR"
```

### Common Issues

#### 1. "Missing Doubao credentials"
- Solution: Ensure secrets are set via `wrangler secret put`

#### 2. "Invalid authentication token"
- Check if user is logged in
- Verify JWT token is present in localStorage
- Check token expiration

#### 3. Connection timeout
- Verify Cloudflare Worker is deployed
- Check network connectivity
- Ensure WebSocket URL is correct

#### 4. Heartbeat not working
- Check backend logs for heartbeat messages
- Verify timer is running (shouldn't be cleared)
- Check if connection is active

#### 5. "ASR service not configured"
- Backend missing DOUBAO_APP_ID or DOUBAO_ACCESS_TOKEN
- Run `wrangler secret list` to verify secrets

## Performance Optimization

### CPU Time Monitoring

Cloudflare Workers have CPU time limits:
- Free tier: 10ms per request
- Paid tier: 50ms per request

This proxy uses minimal CPU (mostly I/O):
- JWT validation: <1ms
- Data forwarding: <1ms each
- Heartbeat checks: <1ms

Total per connection: ~2-3ms setup + minimal per-message overhead

### Connection Limits

Monitor concurrent WebSocket connections:
- Free tier: 1000 connections
- Paid tier: Higher limits (check pricing)

### Optimization Tips

1. **Reduce Logging in Production**
   - Comment out verbose logs if CPU time becomes an issue
   - Keep error logs for debugging

2. **Monitor Metrics**
   - Set up alerts for high error rates
   - Track average connection duration
   - Monitor peak concurrent connections

3. **Consider Durable Objects**
   - If hitting CPU limits, consider Durable Objects
   - Better for long-lived WebSocket connections
   - Higher cost but more reliable

## Security Considerations

1. **JWT Validation**
   - Currently does basic format validation
   - Consider adding signature verification for production
   - Implement rate limiting per user

2. **Credentials Management**
   - Never commit `.env` files
   - Use Cloudflare secrets exclusively in production
   - Rotate credentials periodically

3. **Network Security**
   - Use WSS (secure WebSocket) in production
   - Ensure CORS is properly configured
   - Consider IP allowlisting if needed

## Cost Estimation

### Cloudflare Workers (Free Tier)
- 100,000 requests/day
- WebSocket connections count as requests
- Assume 10 recordings/day/user, 100 users = 1,000 requests/day
- Well within free tier limits

### Paid Tier Considerations
- $5/month for 10M requests
- Additional $0.50 per million requests
- Consider if scaling beyond hobby usage

## Next Steps

1. **Implement Usage Tracking**
   - Log connection count per user
   - Track total audio processing time
   - Store metrics in D1 database

2. **Add Monitoring Dashboard**
   - Create admin panel to view metrics
   - Real-time connection count
   - Error rate graphs

3. **Implement Fallback Strategy**
   - If proxy fails, fall back to direct connection
   - Store credentials encrypted in frontend (temporary)
   - Notify user of degraded service

4. **Performance Optimization**
   - Add response caching where applicable
   - Implement connection pooling
   - Optimize binary protocol parsing

## Support

For issues or questions:
1. Check backend logs: `wrangler tail`
2. Check frontend console logs
3. Review this documentation
4. Check Cloudflare Workers status: https://www.cloudflarestatus.com/
