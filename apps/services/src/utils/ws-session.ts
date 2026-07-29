/**
 * WebSocket session helpers.
 *
 * NOTE: earlier revisions carried a full KV-backed session store here
 * (createSession / getSession / updateSession / incrementCharCount / closeSession).
 * None of it was ever wired into the ASR proxy — quota is settled directly against
 * D1 in asr-proxy.ts — so it was dead code and has been removed. Only the id
 * generator below remains in use (asr-proxy.ts imports generateSessionId).
 */

/**
 * Generate a unique session ID.
 */
export function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).substring(2, 15)}`;
}
