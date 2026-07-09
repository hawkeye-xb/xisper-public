/**
 * Subscription event logging utility.
 *
 * All subscription state changes MUST be recorded via this module.
 * This is the single write path to subscription_events table.
 */

export interface SubscriptionEventInput {
  subscriptionId?: string | null;
  userId: string;
  trigger: 'webhook' | 'cron' | 'admin' | 'resolve' | 'api';
  eventType: 'created' | 'status_changed' | 'tier_changed' | 'reconciled' | 'expired' | 'revoked';
  beforeState?: { status?: string; tier?: string; cancelAtPeriodEnd?: boolean } | null;
  afterState?: { status?: string; tier?: string; cancelAtPeriodEnd?: boolean } | null;
  detail?: Record<string, unknown> | null;
}

/**
 * Insert a subscription event record.
 * Fire-and-forget safe — caller should catch errors.
 */
export async function logSubscriptionEvent(
  db: D1Database,
  input: SubscriptionEventInput,
): Promise<void> {
  const id = crypto.randomUUID();
  const now = Date.now();

  await db.prepare(
    `INSERT INTO subscription_events
       (id, subscription_id, user_id, trigger, event_type, before_state, after_state, detail, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    id,
    input.subscriptionId ?? null,
    input.userId,
    input.trigger,
    input.eventType,
    input.beforeState ? JSON.stringify(input.beforeState) : null,
    input.afterState ? JSON.stringify(input.afterState) : null,
    input.detail ? JSON.stringify(input.detail) : null,
    now,
  ).run();
}
