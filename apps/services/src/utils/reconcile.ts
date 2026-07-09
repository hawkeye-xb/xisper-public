/**
 * Subscription reconciliation.
 *
 * Queries the payment provider API (Creem/Polar) for the real subscription state
 * and syncs differences back to local D1.
 *
 * Currently only Creem is fully supported. Polar reconciliation is a TODO.
 *
 * Two call modes:
 *   - Throttled (default): skips if last_reconciled_at < 1 hour ago
 *   - Force: always queries the provider (used by Cron)
 */

import { getCreemApiBase } from '../config/creem';
import { getPolarApiBase } from '../config/polar';
import { logSubscriptionEvent } from './subscription-event';
import type { SubscriptionRow } from './subscription';

const RECONCILE_THROTTLE_MS = 60 * 60 * 1000; // 1 hour

interface CreemSubscriptionResponse {
  id: string;
  status: string;
  current_period_start_date?: string;
  current_period_end_date?: string;
  canceled_at?: string;
  metadata?: Record<string, string>;
  last_transaction?: {
    period_start?: number;
    period_end?: number;
  };
}

/**
 * Reconcile a single subscription with Creem.
 * Returns the updated local row, or null if skipped / Creem unreachable.
 */
export async function reconcileSubscription(
  db: D1Database,
  sub: SubscriptionRow,
  creemApiKey: string,
  environment: string,
  options?: { force?: boolean; trigger?: 'cron' | 'resolve' | 'api' },
): Promise<SubscriptionRow | null> {
  // Route to appropriate provider reconciliation
  if (sub.source === 'polar') {
    return reconcilePolarSubscription(db, sub, options);
  }

  // Creem reconciliation (existing logic)
  if (sub.source !== 'creem') return null;
  if (!sub.creem_subscription_id) return null;

  // Throttle: skip if reconciled recently (unless forced)
  const force = options?.force ?? false;
  const trigger = options?.trigger ?? 'resolve';
  if (!force && sub.last_reconciled_at) {
    const elapsed = Date.now() - sub.last_reconciled_at;
    if (elapsed < RECONCILE_THROTTLE_MS) {
      return null; // Skip, use local data
    }
  }

  // Query Creem API
  const creemBase = getCreemApiBase(environment);
  let creem: CreemSubscriptionResponse;
  try {
    const resp = await fetch(
      `${creemBase}/subscriptions?subscription_id=${sub.creem_subscription_id}`,
      { headers: { 'x-api-key': creemApiKey } }
    );
    if (!resp.ok) {
      console.warn(`[Reconcile] Creem API returned ${resp.status} for ${sub.creem_subscription_id}`);
      return null;
    }
    creem = await resp.json() as CreemSubscriptionResponse;
  } catch (err) {
    console.warn('[Reconcile] Creem API unreachable:', err);
    return null;
  }

  const now = Date.now();

  // Extract period dates from Creem response (multiple possible fields)
  let periodEnd: number | null = null;
  if (creem.current_period_end_date) {
    periodEnd = new Date(creem.current_period_end_date).getTime();
  } else if (creem.last_transaction?.period_end) {
    periodEnd = creem.last_transaction.period_end;
  }

  let periodStart: number | null = null;
  if (creem.current_period_start_date) {
    periodStart = new Date(creem.current_period_start_date).getTime();
  } else if (creem.last_transaction?.period_start) {
    periodStart = creem.last_transaction.period_start;
  }

  const creemCanceled = !!creem.canceled_at;
  const cancelAtPeriodEnd = creemCanceled ? 1 : 0;

  // Check if anything changed
  const needsUpdate =
    sub.status !== creem.status ||
    sub.current_period_end !== periodEnd ||
    sub.current_period_start !== periodStart ||
    (creemCanceled && sub.cancel_at_period_end !== 1);

  // Always update last_reconciled_at, even if nothing changed
  if (!needsUpdate) {
    await db.prepare(
      'UPDATE subscriptions SET last_reconciled_at = ? WHERE id = ?'
    ).bind(now, sub.id).run();
    return sub;
  }

  // Sync Creem → local
  const beforeState = {
    status: sub.status,
    cancelAtPeriodEnd: sub.cancel_at_period_end === 1,
  };

  await db.prepare(
    `UPDATE subscriptions
     SET status = ?, current_period_start = ?, current_period_end = ?,
         cancel_at_period_end = ?, last_reconciled_at = ?, updated_at = ?
     WHERE id = ?`
  ).bind(creem.status, periodStart, periodEnd, cancelAtPeriodEnd, now, now, sub.id).run();

  // Update user tier based on Creem truth
  const isActive = creem.status === 'active' || creem.status === 'trialing' || creem.status === 'past_due';
  const periodValid = periodEnd != null && periodEnd > now;
  const keepPro = (isActive && (periodValid || !periodEnd)) || (creemCanceled && periodValid);
  const effectiveTier = keepPro ? 'pro' : 'free';

  await db.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind(effectiveTier, now, sub.user_id).run();

  // Log event
  try {
    await logSubscriptionEvent(db, {
      subscriptionId: sub.id,
      userId: sub.user_id,
      trigger,
      eventType: 'reconciled',
      beforeState,
      afterState: {
        status: creem.status,
        tier: effectiveTier,
        cancelAtPeriodEnd: creemCanceled,
      },
      detail: {
        creem_status: creem.status,
        period_end: periodEnd,
        canceled_at: creem.canceled_at ?? null,
      },
    });
  } catch (e) {
    console.error('[Reconcile] Failed to log event:', e);
  }

  console.info(`[Reconcile] Synced sub ${sub.creem_subscription_id}: status=${creem.status} tier=${effectiveTier}`);

  return {
    ...sub,
    status: creem.status,
    current_period_start: periodStart,
    current_period_end: periodEnd,
    cancel_at_period_end: cancelAtPeriodEnd,
    last_reconciled_at: now,
  };
}

/**
 * Reconcile a user's subscription by looking up their latest creem subscription.
 * Convenience wrapper for use in rate-limit/status and subscription/status endpoints.
 */
export async function reconcileUserSubscription(
  db: D1Database,
  userId: string,
  creemApiKey: string,
  environment: string,
): Promise<void> {
  const sub = await db.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) return;

  // Route based on source
  if (sub.source === 'creem' && sub.creem_subscription_id) {
    await reconcileSubscription(db, sub, creemApiKey, environment, {
      force: false,
      trigger: 'resolve',
    });
  }
  // Polar: TODO - implement when needed
}

// ============================================
// Polar Reconciliation
// ============================================

interface PolarSubscriptionResponse {
  id: string;
  status: string;
  current_period_start?: number;
  current_period_end?: number;
  cancel_at_period_end?: boolean;
}

/**
 * Reconcile a Polar subscription.
 * Note: This is a simplified version - full implementation would need
 * Polar API key passed in, similar to Creem.
 */
async function reconcilePolarSubscription(
  db: D1Database,
  sub: SubscriptionRow,
  options?: { force?: boolean; trigger?: 'cron' | 'resolve' | 'api' },
): Promise<SubscriptionRow | null> {
  if (!sub.polar_subscription_id) return null;

  // Throttle: skip if reconciled recently (unless forced)
  const force = options?.force ?? false;
  if (!force && sub.last_reconciled_at) {
    const elapsed = Date.now() - sub.last_reconciled_at;
    if (elapsed < RECONCILE_THROTTLE_MS) {
      return null;
    }
  }

  // TODO: Implement actual Polar API call when POLAR_ACCESS_TOKEN is available
  // For now, just update last_reconciled_at and return local state
  const now = Date.now();
  await db.prepare(
    'UPDATE subscriptions SET last_reconciled_at = ? WHERE id = ?'
  ).bind(now, sub.id).run();

  console.info(`[Reconcile] Polar subscription ${sub.polar_subscription_id} - using local state (Polar reconcile not fully implemented)`);

  return sub;
}
