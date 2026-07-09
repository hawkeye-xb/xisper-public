# Fix: ASR Proxy Flush-Finish Race Condition

## Date: 2026-04-02

## Problem

Beta environment: real-time recording 100% fails with `receivedAsrFinal=false`. Retranscribe works fine. Production unaffected.

## Symptoms

Server-side logs show:

```
Flushing 108 buffered PCM frames (paced 10ms)
Client sent finish                    <- finish arrives during flush
Switched to direct forwarding         <- flush ends AFTER finish was sent
receivedAsrFinal=false                <- upstream never returns final
totalBuffered: 743                    <- 743 frames * 10ms = 7.4s flush duration
```

- Zero text returned from upstream ASR
- Client times out after 8s waiting for final
- Every real-time recording fails; retranscribe always succeeds

## Root Cause

Two independent issues compounded:

### Issue 1: ASR_MODEL secret overriding wrangler.toml vars

Beta had an `ASR_MODEL` secret (old value, probably `fun-asr-*`) that overrode the wrangler.toml var `qwen3-asr-flash-realtime`. This caused beta to use the `alibaba` adapter instead of `qwen3-asr`. Cloudflare secrets take precedence over vars.

**Fix**: Deleted the redundant `ASR_MODEL` secret from beta. Also cleaned up other stale secrets (`DEEPSEEK_API_KEY`, `LOGTO_ENDPOINT`, `DOUBAO_*`) that duplicated wrangler.toml vars.

### Issue 2: 10ms flush pacing causing finish message to be sent out of order

Introduced in commit `c9a34089` (2026-03-24). The flush loop added `await new Promise(r => setTimeout(r, 10))` between each frame to pace delivery and avoid overwhelming the upstream ASR's VAD with burst audio.

**The problem**: The `await` yields the event loop. During these yields, the client's `finish` message is processed by the WebSocket message handler. The handler sees `activeAdapter && asrWS.readyState === WebSocket.OPEN` (both true since upstream connected at step 4), so it sends `session.finish` directly to upstream. But the flush loop still has frames queued — it continues sending audio AFTER the finish signal.

**Upstream receives**: `[audio]...[session.finish]...[audio][audio]...`

Qwen3 ASR does not gracefully handle audio arriving after `session.finish`. Instead of returning partial results, it fails to send `session.finished` entirely.

**Why production was unaffected**: Production was deployed from `91c6c271` (2026-03-23), one day before the pacing was added. Production's flush is synchronous (`for...of` loop, no `await`), so:
- Buffer drains instantly
- `isBuffering` turns false immediately
- Subsequent frames go direct to upstream
- `finish` always arrives in correct order

**Why retranscribe worked**: In retranscribe, the client sends all audio + finish before the proxy connects upstream. When finish arrives, `activeAdapter` is still null, so finish is deferred. After flush completes, deferred finish is sent — correct order.

## Fix Applied

Two changes to `apps/services/src/routes/asr-proxy.ts`:

### 1. Removed 10ms flush pacing

```typescript
// Before (broken):
while (messageBuffer.length > 0) {
    const pcm = messageBuffer.shift()!;
    activeAdapter.sendAudio(asrWS, pcm);
    await new Promise((r) => setTimeout(r, 10)); // yields event loop!
}

// After (fixed):
for (const pcm of messageBuffer) {
    activeAdapter.sendAudio(asrWS, pcm);
}
messageBuffer.length = 0;
```

The 10ms pacing is unnecessary because the client already handles pacing:
- **Retranscribe**: `RetranscribeService.swift` sends 12800-byte chunks with 2ms intervals
- **Real-time**: Audio engine sends frames at natural capture rate

### 2. Added `isBuffering` guard on finish handler

```typescript
// Before: sends finish whenever upstream is connected
if (!finishSentToUpstream && activeAdapter && asrWS?.readyState === WebSocket.OPEN) {

// After: also checks buffer is drained
if (!isBuffering && !finishSentToUpstream && activeAdapter && asrWS?.readyState === WebSocket.OPEN) {
```

This ensures finish is never sent while frames are still queued, even if the flush logic changes in the future.

## Debugging Timeline

1. Initial symptom: 100% ASR timeout on beta, production fine
2. Checked D1 migrations — red herring (both envs had no migrations applied via wrangler, tables created manually)
3. Compared secrets: found `ASR_MODEL` secret on beta overriding var → wrong adapter
4. Fixed secrets, redeployed → still failing (now with correct qwen3 adapter)
5. Captured server logs via `wrangler tail` → saw `Client sent finish` before `Switched to direct forwarding`
6. Traced to `c9a34089` introducing 10ms flush pacing (March 24, one day after prod deploy)
7. Confirmed client-side already handles pacing → removed server-side pacing
8. Deployed fix → verified working

## Lessons

1. **Cloudflare secrets override wrangler.toml vars** — avoid setting secrets for values already in vars. If you must, keep them in sync.
2. **`await` in a loop creates event interleaving opportunities** — WebSocket message handlers can fire during any `await`, breaking expected ordering.
3. **Pacing should be at the source (client), not the relay (proxy)** — the proxy is a transparent relay; it should forward in FIFO order without adding its own timing.
4. **Qwen3 ASR does not tolerate audio after `session.finish`** — it silently fails instead of returning partial results.
