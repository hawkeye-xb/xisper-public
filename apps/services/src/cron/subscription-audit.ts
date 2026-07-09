/**
 * Subscription audit cron job.
 *
 * Runs daily to:
 * 1. Reconcile creem subscriptions with Creem API (forced, ignores throttle)
 * 2. Expire admin/promo subscriptions past period_end
 * 3. Fix users.tier ↔ subscription inconsistencies
 */

import { reconcileSubscription } from '../utils/reconcile';
import { logSubscriptionEvent } from '../utils/subscription-event';
import type { SubscriptionRow } from '../utils/subscription';

interface AuditEnv {
  DB: D1Database;
  CREEM_API_KEY: string;
  ENVIRONMENT: string;
}

interface AuditResult {
  creemReconciled: number;
  creemFailed: number;
  adminExpired: number;
  tierCorrected: number;
}

export async function runSubscriptionAudit(env: AuditEnv): Promise<AuditResult> {
  const result: AuditResult = { creemReconciled: 0, creemFailed: 0, adminExpired: 0, tierCorrected: 0 };
  const now = Date.now();

  // ── Step 1: Reconcile active creem subscriptions ──
  const creemSubs = await env.DB.prepare(
    "SELECT * FROM subscriptions WHERE source = 'creem' AND status IN ('active', 'past_due') LIMIT 100"
  ).all<SubscriptionRow>();

  for (const sub of creemSubs.results || []) {
    try {
      const updated = await reconcileSubscription(
        env.DB, sub, env.CREEM_API_KEY, env.ENVIRONMENT,
        { force: true, trigger: 'cron' },
      );
      if (updated) {
        result.creemReconciled++;
      } else {
        result.creemFailed++;
      }
    } catch (err) {
      console.error(`[Cron] Failed to reconcile sub ${sub.id}:`, err);
      result.creemFailed++;
    }
  }

  // ── Step 2: Expire admin/promo subscriptions past period_end ──
  const expiredAdminSubs = await env.DB.prepare(
    "SELECT id, user_id, source, status FROM subscriptions WHERE source IN ('admin', 'promo') AND status = 'active' AND current_period_end < ?"
  ).bind(now).all<{ id: string; user_id: string; source: string; status: string }>();

  for (const sub of expiredAdminSubs.results || []) {
    await env.DB.prepare(
      "UPDATE subscriptions SET status = 'expired', updated_at = ? WHERE id = ?"
    ).bind(now, sub.id).run();

    try {
      await logSubscriptionEvent(env.DB, {
        subscriptionId: sub.id,
        userId: sub.user_id,
        trigger: 'cron',
        eventType: 'expired',
        beforeState: { status: 'active' },
        afterState: { status: 'expired' },
        detail: { source: sub.source, reason: 'period_end passed' },
      });
    } catch (e) {
      console.error('[Cron] Failed to log admin expiry event:', e);
    }

    result.adminExpired++;
  }

  // ── Step 3: Fix tier inconsistencies ──

  // 3a: users.tier = 'pro' but no valid subscription → downgrade
  const proUsersWithoutSub = await env.DB.prepare(`
    SELECT u.id, u.tier FROM users u
    WHERE u.tier = 'pro'
      AND NOT EXISTS (
        SELECT 1 FROM subscriptions s
        WHERE s.user_id = u.id
          AND (
            s.status IN ('active', 'past_due')
            OR (s.status = 'canceled' AND s.current_period_end > ?)
          )
      )
    LIMIT 100
  `).bind(now).all<{ id: string; tier: string }>();

  for (const user of proUsersWithoutSub.results || []) {
    await env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('free', now, user.id).run();

    try {
      await logSubscriptionEvent(env.DB, {
        userId: user.id,
        trigger: 'cron',
        eventType: 'tier_changed',
        beforeState: { tier: 'pro' },
        afterState: { tier: 'free' },
        detail: { reason: 'no valid subscription found' },
      });
    } catch (e) {
      console.error('[Cron] Failed to log tier downgrade event:', e);
    }

    result.tierCorrected++;
    console.info(`[Cron] Downgraded user ${user.id} to free (no valid subscription)`);
  }

  // 3b: users.tier = 'free' but has valid subscription → upgrade
  const freeUsersWithSub = await env.DB.prepare(`
    SELECT DISTINCT u.id, u.tier FROM users u
    INNER JOIN subscriptions s ON s.user_id = u.id
    WHERE u.tier = 'free'
      AND (
        s.status IN ('active', 'past_due')
        OR (s.status = 'canceled' AND s.current_period_end > ?)
      )
    LIMIT 100
  `).bind(now).all<{ id: string; tier: string }>();

  for (const user of freeUsersWithSub.results || []) {
    await env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('pro', now, user.id).run();

    try {
      await logSubscriptionEvent(env.DB, {
        userId: user.id,
        trigger: 'cron',
        eventType: 'tier_changed',
        beforeState: { tier: 'free' },
        afterState: { tier: 'pro' },
        detail: { reason: 'valid subscription found (webhook missed)' },
      });
    } catch (e) {
      console.error('[Cron] Failed to log tier upgrade event:', e);
    }

    result.tierCorrected++;
    console.info(`[Cron] Upgraded user ${user.id} to pro (valid subscription exists)`);
  }

  return result;
}
