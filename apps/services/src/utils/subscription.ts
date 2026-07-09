/**
 * Subscription-aware tier resolution.
 *
 * The single source of truth for "what tier is this user RIGHT NOW?"
 *
 * Rules:
 *   1. Special tiers (enterprise, unlimited) are never overridden.
 *   2. Query ALL subscriptions (any source) for effective status.
 *   3. Pick the "best" active subscription (priority: active/past_due > canceled-in-period).
 *   4. Among equals, pick the one with the latest period_end.
 *   5. If effective tier differs from users.tier, auto-correct and log event.
 *
 * Call this instead of raw `SELECT tier FROM users` in any quota-gated path.
 */

import type { UserTier } from '../config/rate-limits';
import { normalizeTier } from '../config/rate-limits';
import { logSubscriptionEvent } from './subscription-event';

export interface SubscriptionRow {
  id: string;
  user_id: string;
  source: string;
  plan: string;
  status: string;
  current_period_start: number | null;
  current_period_end: number | null;
  cancel_at_period_end: number;
  last_reconciled_at: number | null;
  creem_subscription_id: string | null;
  creem_customer_id: string | null;
  creem_checkout_id: string | null;
  polar_subscription_id: string | null;
  polar_customer_id: string | null;
  polar_checkout_id: string | null;
  paddle_subscription_id: string | null;
  paddle_customer_id: string | null;
  created_at: number;
  updated_at: number;
  metadata: string | null;
}

export interface SubscriptionInfo {
  status: string | null;
  currentPeriodEnd: number | null;
  cancelAtPeriodEnd: boolean;
  source: string | null;
}

export interface TierResolution {
  tier: UserTier;
  subscription: SubscriptionInfo;
  /** The full subscription row, if one was found. For internal use (reconcile etc). */
  raw: SubscriptionRow | null;
}

const NO_SUB: SubscriptionInfo = { status: null, currentPeriodEnd: null, cancelAtPeriodEnd: false, source: null };

/**
 * Resolve the effective tier for a user.
 */
export async function resolveUserTier(
  db: D1Database,
  userId: string,
): Promise<UserTier> {
  const result = await resolveUserTierWithInfo(db, userId);
  return result.tier;
}

/**
 * Same as resolveUserTier but also returns subscription metadata.
 */
export async function resolveUserTierWithInfo(
  db: D1Database,
  userId: string,
): Promise<TierResolution> {
  const user = await db.prepare(
    'SELECT tier FROM users WHERE id = ?'
  ).bind(userId).first<{ tier: string }>();

  const rawTier = normalizeTier(user?.tier);

  // Special tiers are authoritative — never touch them
  if (rawTier === 'enterprise' || rawTier === 'unlimited') {
    return { tier: rawTier, subscription: NO_SUB, raw: null };
  }

  const now = Date.now();

  // Find the user's subscription. One user = one effective subscription at a time.
  // canceled + period not ended = still valid (user paid for this period).
  const sub = await db.prepare(`
    SELECT * FROM subscriptions
    WHERE user_id = ?
      AND (
        status IN ('active', 'past_due')
        OR (status = 'canceled' AND current_period_end > ?)
      )
    ORDER BY created_at DESC
    LIMIT 1
  `).bind(userId, now).first<SubscriptionRow>();

  const effectiveTier: UserTier = sub ? 'pro' : 'free';

  const subInfo: SubscriptionInfo = sub
    ? {
        status: sub.status,
        currentPeriodEnd: sub.current_period_end,
        cancelAtPeriodEnd: sub.cancel_at_period_end === 1,
        source: sub.source,
      }
    : NO_SUB;

  // Auto-correct users.tier if it drifted
  if (rawTier !== effectiveTier) {
    await db.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind(effectiveTier, now, userId).run();

    try {
      await logSubscriptionEvent(db, {
        subscriptionId: sub?.id ?? null,
        userId,
        trigger: 'resolve',
        eventType: 'tier_changed',
        beforeState: { tier: rawTier },
        afterState: { tier: effectiveTier, status: sub?.status },
        detail: { reason: 'auto-correct in resolveUserTier' },
      });
    } catch (e) {
      console.error('[Subscription] Failed to log tier correction event:', e);
    }

    if (effectiveTier === 'free') {
      console.info(`[Subscription] Auto-downgraded user ${userId} to free`);
    } else {
      console.info(`[Subscription] Auto-upgraded user ${userId} to pro`);
    }
  }

  return { tier: effectiveTier, subscription: subInfo, raw: sub };
}
