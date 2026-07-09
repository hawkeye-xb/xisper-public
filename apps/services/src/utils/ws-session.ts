/**
 * WebSocket Session Management
 * 
 * Manages ASR WebSocket sessions and tracks usage metrics
 */

import { KV_KEYS, type UserTier } from '../config/rate-limits';

export interface SessionData {
  userId: string;
  tier: UserTier;
  startTime: number;
  charCount: number;
  sessionId: string;
}

/**
 * Create a new WebSocket session record in KV
 */
export async function createSession(
  kv: KVNamespace,
  userId: string,
  tier: UserTier,
  sessionId: string
): Promise<SessionData> {
  const sessionData: SessionData = {
    userId,
    tier,
    startTime: Date.now(),
    charCount: 0,
    sessionId,
  };

  const kvKey = KV_KEYS.WS_SESSION(userId, sessionId);
  
  // Store session with 24 hour TTL (sessions shouldn't last that long anyway)
  await kv.put(kvKey, JSON.stringify(sessionData), { expirationTtl: 86400 });

  return sessionData;
}

/**
 * Get session data from KV
 */
export async function getSession(
  kv: KVNamespace,
  userId: string,
  sessionId: string
): Promise<SessionData | null> {
  const kvKey = KV_KEYS.WS_SESSION(userId, sessionId);
  const sessionDataStr = await kv.get(kvKey);

  if (!sessionDataStr) {
    return null;
  }

  try {
    return JSON.parse(sessionDataStr) as SessionData;
  } catch (error) {
    console.error('[WS Session] Failed to parse session data:', error);
    return null;
  }
}

/**
 * Update session data (e.g., increment character count)
 */
export async function updateSession(
  kv: KVNamespace,
  userId: string,
  sessionId: string,
  updates: Partial<Pick<SessionData, 'charCount'>>
): Promise<boolean> {
  const session = await getSession(kv, userId, sessionId);
  
  if (!session) {
    console.error('[WS Session] Session not found:', sessionId);
    return false;
  }

  const updatedSession: SessionData = {
    ...session,
    ...updates,
  };

  const kvKey = KV_KEYS.WS_SESSION(userId, sessionId);
  await kv.put(kvKey, JSON.stringify(updatedSession), { expirationTtl: 86400 });

  return true;
}

/**
 * Increment character count for a session
 */
export async function incrementCharCount(
  kv: KVNamespace,
  userId: string,
  sessionId: string,
  charCount: number
): Promise<number> {
  const session = await getSession(kv, userId, sessionId);
  
  if (!session) {
    console.error('[WS Session] Session not found for char increment:', sessionId);
    return 0;
  }

  const newCharCount = session.charCount + charCount;
  await updateSession(kv, userId, sessionId, { charCount: newCharCount });

  return newCharCount;
}

/**
 * Calculate session duration in seconds
 */
export function getSessionDuration(session: SessionData): number {
  const now = Date.now();
  const durationMs = now - session.startTime;
  return Math.floor(durationMs / 1000);
}

/**
 * Close session and return final metrics
 */
export async function closeSession(
  kv: KVNamespace,
  userId: string,
  sessionId: string
): Promise<{
  duration: number;
  charCount: number;
  tier: UserTier;
} | null> {
  const session = await getSession(kv, userId, sessionId);

  if (!session) {
    console.error('[WS Session] Session not found for closing:', sessionId);
    return null;
  }

  const duration = getSessionDuration(session);
  const metrics = {
    duration,
    charCount: session.charCount,
    tier: session.tier,
  };

  // Delete session from KV
  const kvKey = KV_KEYS.WS_SESSION(userId, sessionId);
  await kv.delete(kvKey);

  return metrics;
}

/**
 * Generate a unique session ID
 */
export function generateSessionId(): string {
  return `session_${Date.now()}_${Math.random().toString(36).substring(2, 15)}`;
}
