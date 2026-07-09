/**
 * Rate Limit Configuration
 * 
 * Defines quota limits for different user tiers and reset schedules
 */

export type UserTier = 'free' | 'pro' | 'enterprise' | 'unlimited';

const VALID_TIERS: readonly string[] = ['free', 'pro', 'enterprise', 'unlimited'];

export interface CustomQuotaLimits {
  llmCalls?: number;
  asrDuration?: number;
  asrCharacters?: number;
}

export function normalizeTier(raw: unknown): UserTier {
  const value = String(raw ?? '').toLowerCase().trim();
  return VALID_TIERS.includes(value) ? (value as UserTier) : 'free';
}

export interface LLMQuotaConfig {
  calls: number;      // Number of API calls allowed
  window: number;     // Time window in seconds
}

export interface ASRQuotaConfig {
  duration: number;   // Maximum connection duration in seconds
  characters: number; // Maximum character count
  window: number;     // Time window in seconds
}

export interface TierConfig {
  llm: LLMQuotaConfig;
  asr: ASRQuotaConfig;
}

/**
 * Rate limit configuration by user tier
 *
 * Calculations:
 * - Free: 900 calls/day, 75 min ASR, 10000 chars
 * - Pro: 3200 calls/day, 13.3 hr ASR, 80000 chars
 * - Enterprise: 300 calls/hour * 12 hours = 3600 calls/day
 */
export const RATE_LIMIT_CONFIG: Record<UserTier, TierConfig> = {
  free: {
    llm: {
      calls: 900,        // 900 calls per day
      window: 86400,     // 24 hours in seconds
    },
    asr: {
      duration: 4500,    // 75 minutes per week (in seconds)
      characters: 10000, // 10000 characters per week
      window: 604800,    // 7 days in seconds
    },
  },
  pro: {
    llm: {
      calls: 3200,       // 3200 calls per day
      window: 86400,
    },
    asr: {
      duration: 48000,   // ~13.3 hours per week (in seconds)
      characters: 80000, // 80000 characters per week
      window: 604800,
    },
  },
  enterprise: {
    llm: {
      calls: 3600,       // 3600 calls per day (10x free)
      window: 86400,
    },
    asr: {
      duration: 72000,   // 20 hours per week (in seconds)
      characters: 150000, // 150000 characters per week (37.5x free)
      window: 604800,
    },
  },
  unlimited: {
    llm: {
      calls: 999999,
      window: 86400,
    },
    asr: {
      duration: 360000,    // 100 hours per week
      characters: 10000000, // 10M characters per week
      window: 604800,
    },
  },
};

/**
 * Reset time configuration
 * All times in UTC (Beijing time - 8 hours)
 * 
 * - LLM: Daily reset at 03:00 Beijing Time (19:00 UTC)
 * - ASR: Weekly reset on Monday at 03:00 Beijing Time (19:00 UTC Sunday)
 */
export const RESET_CONFIG = {
  llm: {
    hour: 19,        // 19:00 UTC = 03:00 Beijing Time (next day)
    minute: 0,
  },
  asr: {
    dayOfWeek: 1,    // Monday (cron uses 0-6, 0 = Sunday)
    hour: 19,        // 19:00 UTC = 03:00 Beijing Time (Monday)
    minute: 0,
  },
};

/**
 * KV Key prefixes for rate limiting
 */
export const KV_KEYS = {
  LLM: (userId: string, date: string) => `rate:llm:${userId}:${date}`,
  ASR_DURATION: (userId: string, week: string) => `rate:asr:duration:${userId}:${week}`,
  ASR_CHARS: (userId: string, week: string) => `rate:asr:chars:${userId}:${week}`,
  WS_SESSION: (userId: string, sessionId: string) => `ws:session:${userId}:${sessionId}`,
  CUSTOM_LIMITS: (userId: string) => `quota_limits:${userId}`,
};

/**
 * Resolve effective tier config with per-user custom overrides.
 * Custom limits stored in KV take precedence over tier defaults.
 */
export function resolveEffectiveLimits(tier: UserTier, custom: CustomQuotaLimits | null): TierConfig {
  const base = RATE_LIMIT_CONFIG[tier];
  if (!custom) return base;
  return {
    llm: { ...base.llm, calls: custom.llmCalls ?? base.llm.calls },
    asr: {
      ...base.asr,
      duration: custom.asrDuration ?? base.asr.duration,
      characters: custom.asrCharacters ?? base.asr.characters,
    },
  };
}

/**
 * Get date key in YYYY-MM-DD format
 */
export function getDateKey(date: Date = new Date()): string {
  return date.toISOString().split('T')[0];
}

/**
 * Get week key in YYYY-Www format (ISO week)
 */
export function getWeekKey(date: Date = new Date()): string {
  const year = date.getUTCFullYear();
  const startOfYear = new Date(Date.UTC(year, 0, 1));
  const daysSinceStart = Math.floor((date.getTime() - startOfYear.getTime()) / (24 * 60 * 60 * 1000));
  const weekNumber = Math.ceil((daysSinceStart + startOfYear.getUTCDay() + 1) / 7);
  return `${year}-W${String(weekNumber).padStart(2, '0')}`;
}

/**
 * Calculate next reset time for LLM quota (daily at 03:00 Beijing Time)
 */
export function getNextLLMResetTime(now: Date = new Date()): Date {
  const resetTime = new Date(now);
  resetTime.setUTCHours(RESET_CONFIG.llm.hour, RESET_CONFIG.llm.minute, 0, 0);
  
  // If current time is past reset time, move to next day
  if (now >= resetTime) {
    resetTime.setUTCDate(resetTime.getUTCDate() + 1);
  }
  
  return resetTime;
}

/**
 * Calculate next reset time for ASR quota (Monday at 03:00 Beijing Time)
 */
export function getNextASRResetTime(now: Date = new Date()): Date {
  const resetTime = new Date(now);
  resetTime.setUTCHours(RESET_CONFIG.asr.hour, RESET_CONFIG.asr.minute, 0, 0);
  
  const currentDay = now.getUTCDay();
  const targetDay = RESET_CONFIG.asr.dayOfWeek;
  
  let daysUntilReset = targetDay - currentDay;
  if (daysUntilReset < 0 || (daysUntilReset === 0 && now >= resetTime)) {
    daysUntilReset += 7;
  }
  
  resetTime.setUTCDate(resetTime.getUTCDate() + daysUntilReset);
  
  return resetTime;
}

/**
 * Get TTL for KV entries
 */
export function getLLMQuotaTTL(): number {
  const now = new Date();
  const nextReset = getNextLLMResetTime(now);
  return Math.ceil((nextReset.getTime() - now.getTime()) / 1000) + 3600; // Add 1 hour buffer
}

export function getASRQuotaTTL(): number {
  const now = new Date();
  const nextReset = getNextASRResetTime(now);
  return Math.ceil((nextReset.getTime() - now.getTime()) / 1000) + 3600; // Add 1 hour buffer
}
