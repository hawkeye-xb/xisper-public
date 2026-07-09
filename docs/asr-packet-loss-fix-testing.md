# ASR Packet Loss Fix - Testing Guide

## Overview

This document provides testing instructions for the ASR WebSocket proxy packet loss fix implemented in `apps/services/src/routes/asr-proxy.ts`.

## Changes Summary

### Fixed Issues

1. **First Packet Loss (Head Packet Loss)**: Audio packets sent by the client during ASR connection establishment were lost
2. **Last Packet Loss (Tail Packet Loss)**: Audio packets in flight when the client closed the connection were lost

### Implementation

1. **Message Buffering**: Client connection is accepted immediately and messages are buffered until Doubao ASR connection is established
2. **Graceful Close**: When client closes, wait for in-flight messages and send finish packet before closing ASR connection
3. **Buffer Monitoring**: Added statistics tracking for buffer size and dropped packets

## Testing Instructions

### Prerequisites

1. Ensure both services are running:
   ```bash
   # Terminal 1: Start backend service
   cd apps/services
   pnpm dev
   
   # Terminal 2: Start frontend
   cd apps/web
   pnpm dev
   ```

2. Login to the application with a valid account

### Test 1: First Packet Verification (Head Packet Test)

**Purpose**: Verify that audio from the beginning of recording is captured correctly

**Steps**:
1. Start recording in the application
2. **Immediately** say "你好世界" (or "Hello World")
3. Wait 2 seconds, then stop recording
4. Check backend logs for:
   ```
   [ASR Proxy] Client connection accepted
   [ASR Proxy] Connecting to Doubao ASR...
   [ASR Proxy] Connected to Doubao ASR
   [ASR Proxy] Flushing N buffered messages  # N should be > 0
   [ASR Proxy] Switched to direct forwarding mode
   ```
5. **Verify**: The transcription result includes the complete "你好世界" (or "Hello World")

**Expected Result**:
- ✅ Buffer statistics show N > 0 messages buffered
- ✅ Complete text recognized from the start
- ✅ No missing or truncated words at the beginning

**Before Fix**: First 1-3 seconds of audio would be lost, resulting in incomplete transcription

### Test 2: Last Packet Verification (Tail Packet Test)

**Purpose**: Verify that audio at the end of recording is captured correctly

**Steps**:
1. Start recording
2. Say "这是第一句话" (This is the first sentence)
3. Wait 1 second
4. Say "这是最后一句话" (This is the last sentence)
5. **Immediately** stop recording (don't wait)
6. Check backend logs for:
   ```
   [ASR Proxy] Client initiated close
   [ASR Proxy] Sent finish packet to ASR
   [ASR Proxy] Connections closed gracefully
   [ASR Proxy] Session stats: { duration: "Xs", chars: N, bufferMaxSize: M, ... }
   ```
7. **Verify**: The transcription result includes the complete "这是最后一句话"

**Expected Result**:
- ✅ Graceful close message appears in logs
- ✅ Complete text recognized until the end
- ✅ No missing or truncated words at the end

**Before Fix**: Last 0.5-1 second of audio would be lost, resulting in incomplete final sentence

### Test 3: Buffer Overflow Test

**Purpose**: Verify buffer handles slow ASR connection gracefully

**Steps**:
1. Temporarily add artificial delay to ASR connection (for testing only):
   ```typescript
   // In handleASRProxyConnection, after line "await new Promise..."
   await new Promise(resolve => setTimeout(resolve, 5000)); // Add 5 second delay
   ```
2. Start recording
3. Continuously speak for 10 seconds
4. Stop recording
5. Check backend logs for:
   ```
   [ASR Proxy] Buffer overflow: dropping oldest messages
   [ASR Proxy] Session stats: { ..., bufferMaxSize: 50, totalBuffered: X, dropped: Y }
   ```

**Expected Result**:
- ✅ Buffer size reaches MAX_BUFFER_SIZE (50)
- ✅ Warning logged when overflow occurs
- ✅ Oldest messages dropped, newest messages preserved
- ✅ No crash or error

**Note**: Remove the artificial delay after testing

### Test 4: Normal Flow Regression Test

**Purpose**: Ensure the fix doesn't break normal operation

**Test Scenarios**:
1. **Short recording** (1-2 seconds): Start, say something, stop
2. **Medium recording** (5-10 seconds): Normal conversation
3. **Long recording** (30+ seconds): Extended speech with pauses
4. **Multiple sessions**: Start/stop recording multiple times in succession
5. **Concurrent connections**: Multiple users recording simultaneously (if applicable)

**For each scenario, verify**:
- ✅ Connection establishes successfully
- ✅ Audio is transcribed correctly
- ✅ No errors in backend logs
- ✅ Session metrics are logged correctly
- ✅ Quota consumption works properly

### Test 5: Error Handling

**Purpose**: Verify graceful error handling

**Scenarios**:
1. **ASR connection timeout**: Temporarily use invalid Doubao credentials
   - Expected: Error logged, client connection closed with error message
2. **Client disconnect during buffering**: Start recording, immediately close app
   - Expected: Buffer cleared, connections cleaned up
3. **Network interruption**: Disconnect network during recording
   - Expected: Connection closes gracefully, no hanging connections

## Monitoring & Validation

### Key Log Messages

Look for these messages to confirm the fix is working:

```bash
# Connection flow
[ASR Proxy] Session started: {sessionId}
[ASR Proxy] Client connection accepted
[ASR Proxy] Connecting to Doubao ASR...
[ASR Proxy] Connected to Doubao ASR
[ASR Proxy] Flushing N buffered messages
[ASR Proxy] Switched to direct forwarding mode

# Graceful close
[ASR Proxy] Client initiated close
[ASR Proxy] Sent finish packet to ASR
[ASR Proxy] Connections closed gracefully

# Session statistics
[ASR Proxy] Session stats: {
  duration: "10s",
  chars: 25,
  bufferMaxSize: 5,
  totalBuffered: 5,
  dropped: 0
}
```

### Buffer Statistics Interpretation

In the session stats:
- `bufferMaxSize`: Maximum number of packets buffered (should be 2-10 for normal connections)
- `totalBuffered`: Total packets that went through buffer (first few packets)
- `dropped`: Number of packets dropped due to buffer overflow (should be 0 normally)

**Warning Signs**:
- `bufferMaxSize > 30`: ASR connection is very slow
- `dropped > 0`: Buffer overflowed (connection too slow or too much data)
- `bufferMaxSize = 0`: Something might be wrong with the buffering logic

## Success Criteria

All tests pass if:
1. ✅ No audio lost at the beginning (first 1-3 seconds captured)
2. ✅ No audio lost at the end (last 0.5-1 second captured)
3. ✅ Buffer statistics show proper buffering (maxSize 2-10)
4. ✅ No increase in errors or crashes
5. ✅ Recognition accuracy maintained or improved
6. ✅ Quota tracking still works correctly

## Performance Impact

Expected performance characteristics:
- **Latency**: +0-100ms for buffering (negligible)
- **Memory**: +50-160KB per connection (negligible)
- **CPU**: No measurable increase
- **Connection duration**: +300-800ms for graceful close

## Rollback Procedure

If issues are found:

1. Revert the changes in `apps/services/src/routes/asr-proxy.ts`
2. Redeploy the service:
   ```bash
   cd apps/services
   git checkout HEAD~1 -- src/routes/asr-proxy.ts
   pnpm deploy
   ```
3. Verify old behavior returns (with packet loss but stable)

## Next Steps After Testing

If all tests pass:

1. ✅ Mark testing TODO as complete
2. ✅ Deploy to staging environment for extended testing
3. ✅ Monitor production metrics for 24-48 hours
4. ✅ Collect user feedback on transcription quality
5. ✅ Document any issues found
6. ✅ Consider implementing optional enhancements (dynamic buffer, connection pool)

## Known Limitations

1. **Buffer size**: Fixed at 50 packets (~5 seconds). If ASR connection takes >5 seconds, some packets will be dropped
2. **Graceful close delay**: Adds 800ms to connection close time
3. **Memory usage**: Each connection uses ~160KB for buffer (acceptable for most cases)

## Troubleshooting

### Issue: Buffer always shows maxSize=0

**Cause**: ASR connection is very fast, no buffering needed
**Resolution**: This is actually good! No buffering needed means fast connection

### Issue: Buffer frequently overflows (dropped > 0)

**Cause**: ASR connection is consistently slow
**Resolution**: Consider increasing MAX_BUFFER_SIZE or investigate ASR endpoint performance

### Issue: Still seeing packet loss

**Cause**: Other networking issues or client-side problems
**Resolution**: Check network latency, verify client sends packets correctly

## Contact

For issues or questions about this fix:
- Check backend logs: `wrangler tail` (dev) or `wrangler tail --env production` (prod)
- Review plan document: `.cursor/plans/asr_数据包丢失修复_*.plan.md`
- Consult implementation: `apps/services/src/routes/asr-proxy.ts` lines 111-400
