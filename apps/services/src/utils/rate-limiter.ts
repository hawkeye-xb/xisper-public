/**
 * Rate Limiter Utilities
 * 
 * Provides functions to check and consume quota for LLM and ASR services
 */

import {
  KV_KEYS,
  getDateKey,
  getWeekKey,
  getNextLLMResetTime,
  getNextASRResetTime,
  resolveEffectiveLimits,
  type UserTier,
  type CustomQuotaLimits,
} from '../config/rate-limits';

export interface QuotaCheckResult {
  allowed: boolean;
  current: number;
  limit: number;
  remaining: number;
  resetAt: Date;
  resetIn: number;
}

/**
 * Fetch per-user custom quota limits from KV (if any).
 * Call once per request, pass the result to check/consume functions.
 */
export async function fetchCustomLimits(
  kv: KVNamespace,
  userId: string,
): Promise<CustomQuotaLimits | null> {
  return await kv.get<CustomQuotaLimits>(KV_KEYS.CUSTOM_LIMITS(userId), 'json');
}

/**
 * Check LLM API quota for a user
 */
export async function checkLLMQuota(
  kv: KVNamespace,
  userId: string,
  tier: UserTier = 'free',
  customLimits?: CustomQuotaLimits | null,
): Promise<QuotaCheckResult> {
  const effective = resolveEffectiveLimits(tier, customLimits ?? null);
  const config = effective.llm;
  const dateKey = getDateKey();
  const kvKey = KV_KEYS.LLM(userId, dateKey);

  const currentUsageStr = await kv.get(kvKey);
  const currentUsage = currentUsageStr ? parseInt(currentUsageStr, 10) : 0;

  const resetAt = getNextLLMResetTime();
  const resetIn = Math.ceil((resetAt.getTime() - Date.now()) / 1000);

  return {
    allowed: currentUsage < config.calls,
    current: currentUsage,
    limit: config.calls,
    remaining: Math.max(0, config.calls - currentUsage),
    resetAt,
    resetIn,
  };
}

/**
 * Check ASR quota (both duration and characters) - uses D1 when available
 */
export async function checkASRQuota(
  kv: KVNamespace,
  userId: string,
  tier: UserTier = 'free',
  customLimits?: CustomQuotaLimits | null,
  d1?: any,
): Promise<{
  duration: QuotaCheckResult;
  characters: QuotaCheckResult;
}> {
  const effective = resolveEffectiveLimits(tier, customLimits ?? null);
  const config = effective.asr;
  const weekKey = getWeekKey();
  const resetAt = getNextASRResetTime();
  const resetIn = Math.ceil((resetAt.getTime() - Date.now()) / 1000);

  let durationUsage = 0;
  let charsUsage = 0;

  // Try D1 first
  if (d1) {
    try {
      const result = await d1.prepare(
        'SELECT duration_used, characters_used FROM user_asr_quota WHERE user_id = ? AND week_key = ?'
      ).bind(userId, weekKey).first<{ duration_used: number; characters_used: number }>();

      if (result) {
        durationUsage = result.duration_used;
        charsUsage = result.characters_used;
        console.log('[RateLimiter] Quota checked via D1:', { userId, weekKey, durationUsage, charsUsage });
      }
    } catch (e) {
      console.warn('[RateLimiter] D1 read failed, fallback to KV:', (e as Error).message);
      const durationKey = KV_KEYS.ASR_DURATION(userId, weekKey);
      const durationUsageStr = await kv.get(durationKey);
      durationUsage = durationUsageStr ? parseInt(durationUsageStr, 10) : 0;
      const charsKey = KV_KEYS.ASR_CHARS(userId, weekKey);
      const charsUsageStr = await kv.get(charsKey);
      charsUsage = charsUsageStr ? parseInt(charsUsageStr, 10) : 0;
    }
  } else {
    const durationKey = KV_KEYS.ASR_DURATION(userId, weekKey);
    const durationUsageStr = await kv.get(durationKey);
    durationUsage = durationUsageStr ? parseInt(durationUsageStr, 10) : 0;
    const charsKey = KV_KEYS.ASR_CHARS(userId, weekKey);
    const charsUsageStr = await kv.get(charsKey);
    charsUsage = charsUsageStr ? parseInt(charsUsageStr, 10) : 0;
  }

  return {
    duration: {
      allowed: durationUsage < config.duration,
      current: durationUsage,
      limit: config.duration,
      remaining: Math.max(0, config.duration - durationUsage),
      resetAt,
      resetIn,
    },
    characters: {
      allowed: charsUsage < config.characters,
      current: charsUsage,
      limit: config.characters,
      remaining: Math.max(0, config.characters - charsUsage),
      resetAt,
      resetIn,
    },
  };
}

/**
 * Get current quota usage for a user
 */
export async function getQuotaStatus(
  kv: KVNamespace,
  userId: string,
  tier: UserTier = 'free',
  customLimits?: CustomQuotaLimits | null,
  d1?: any,
) {
  const llmQuota = await checkLLMQuota(kv, userId, tier, customLimits);
  const asrQuota = await checkASRQuota(kv, userId, tier, customLimits, d1);

  return {
    userId,
    tier,
    llm: {
      limit: llmQuota.limit,
      used: llmQuota.current,
      remaining: llmQuota.remaining,
      resetAt: llmQuota.resetAt.toISOString(),
      resetIn: llmQuota.resetIn,
    },
    asr: {
      duration: {
        limit: asrQuota.duration.limit,
        used: asrQuota.duration.current,
        remaining: asrQuota.duration.remaining,
      },
      characters: {
        limit: asrQuota.characters.limit,
        used: asrQuota.characters.current,
        remaining: asrQuota.characters.remaining,
      },
      resetAt: asrQuota.duration.resetAt.toISOString(),
      resetIn: asrQuota.duration.resetIn,
    },
  };
}
