/**
 * Paddle Webhook Handler
 *
 * Handles webhook events from Paddle payment platform.
 * Docs: https://developer.paddle.com/webhooks
 */

import { Hono } from 'hono';
import { logSubscriptionEvent } from '../../utils/subscription-event';
import type { SubscriptionRow } from '../../utils/subscription';

type Bindings = {
  DB: D1Database;
  PADDLE_WEBHOOK_SECRET: string;
  PADDLE_ACCESS_TOKEN?: string;
  PADDLE_VENDOR_ID?: string;
  SERVICE_BASE_URL?: string;
};

const paddleWebhooks = new Hono<{ Bindings: Bindings }>();

// ============================================
// POST /webhooks/paddle — Paddle webhook receiver
// ============================================
paddleWebhooks.post('/', async (c) => {
  const secret = c.env.PADDLE_WEBHOOK_SECRET;
  if (!secret) {
    console.error('[Paddle Webhook] PADDLE_WEBHOOK_SECRET not configured');
    return c.json({ error: 'Webhook not configured' }, 500);
  }

  const signature = c.req.header('paddle-signature');
  const rawBody = await c.req.text();

  // Verify signature (Paddle uses specific signature format)
  // For now, just log and process
  if (!signature) {
    console.warn('[Paddle Webhook] Missing paddle-signature header');
  }

  let event: PaddleWebhookEvent;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return c.json({ error: 'Invalid JSON' }, 400);
  }

  const eventType = event.event_type || event.type;
  console.info(`[Paddle Webhook] Received event: ${eventType}`);

  try {
    switch (eventType) {
      case 'subscription.created':
        await handleSubscriptionCreated(c, event);
        break;
      case 'subscription.activated':
        await handleSubscriptionActivated(c, event);
        break;
      case 'subscription.updated':
        await handleSubscriptionUpdated(c, event);
        break;
      case 'subscription.canceled':
        await handleSubscriptionCanceled(c, event);
        break;
      case 'subscription.expired':
        await handleSubscriptionExpired(c, event);
        break;
      case 'subscription.past_due':
        await handleSubscriptionPastDue(c, event);
        break;
      case 'transaction.completed':
        await handleTransactionCompleted(c, event);
        break;
      default:
        console.info(`[Paddle Webhook] Unhandled event type: ${eventType}`);
    }
  } catch (err) {
    console.error(`[Paddle Webhook] Error handling ${eventType}:`, err);
  }

  return c.json({ received: true });
});

// Health check
paddleWebhooks.get('/', (c) => {
  return c.json({ status: 'ok', provider: 'paddle' });
});

// ============================================
// Types
// ============================================

interface PaddleWebhookEvent {
  event_type?: string;
  type?: string;
  data?: {
    id: string;
    status?: string;
    customer_id?: string;
    subscription_id?: string;
    custom_data?: Record<string, string>;
    items?: Array<{
      price?: { id: string };
    }>;
    billing_period?: {
      start?: string;
      end?: string;
    };
    current_billing_period?: {
      starts_at?: number;
      ends_at?: number;
    };
    cancel_at_period_end?: boolean;
    [key: string]: any;
  };
  [key: string]: any;
}

// ============================================
// Event Handlers
// ============================================

async function handleSubscriptionCreated(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  const customerId = data?.customer_id;
  const userId = data?.custom_data?.user_id;

  if (!userId) {
    console.warn('[Paddle Webhook] subscription.created missing user_id');
    return;
  }

  console.info(`[Paddle Webhook] Subscription created: ${subscriptionId}, user: ${userId}`);
}

async function handleSubscriptionActivated(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  const customerId = data?.customer_id;
  const userId = data?.custom_data?.user_id;

  if (!userId) {
    console.warn('[Paddle Webhook] subscription.activated missing user_id');
    return;
  }

  const now = Date.now();
  const periodEnd = data?.current_billing_period?.ends_at
    ? new Date(data.current_billing_period.ends_at).getTime()
    : null;
  const periodStart = data?.current_billing_period?.starts_at
    ? new Date(data.current_billing_period.starts_at).getTime()
    : now;

  // Idempotent: check if already exists
  const existing = await c.env.DB.prepare(
    'SELECT id FROM subscriptions WHERE paddle_subscription_id = ?'
  ).bind(subscriptionId).first();

  if (existing) {
    console.info(`[Paddle Webhook] subscription.activated already exists: ${subscriptionId}`);
    return;
  }

  const id = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO subscriptions
       (id, user_id, source, paddle_subscription_id, paddle_customer_id,
        plan, status, current_period_start, current_period_end, created_at, updated_at)
     VALUES (?, ?, 'paddle', ?, ?, 'pro_monthly', 'active', ?, ?, ?, ?)`
  ).bind(
    id, userId, subscriptionId, customerId,
    periodStart, periodEnd, now, now
  ).run();

  await c.env.DB.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind('pro', now, userId).run();

  try {
    await logSubscriptionEvent(c.env.DB, {
      subscriptionId: id,
      userId,
      trigger: 'webhook',
      eventType: 'created',
      afterState: { status: 'active', tier: 'pro' },
      detail: { paddle_subscription_id: subscriptionId },
    });
  } catch (e) {
    console.error('[Paddle Webhook] Failed to log event:', e);
  }

  console.info(`[Paddle Webhook] User ${userId} upgraded to pro (source=paddle)`);
}

async function handleSubscriptionUpdated(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  if (!subscriptionId) return;

  const now = Date.now();
  const sub = await c.env.DB.prepare(
    'SELECT id, user_id, status, cancel_at_period_end FROM subscriptions WHERE paddle_subscription_id = ?'
  ).bind(subscriptionId).first<{ id: string; user_id: string; status: string; cancel_at_period_end: number }>();

  if (!sub) return;

  const beforeState = { status: sub.status, cancelAtPeriodEnd: sub.cancel_at_period_end === 1 };

  // Sync status, cancel_at_period_end, and billing period from Paddle
  const newStatus = data?.status || sub.status;
  const scheduledChange = data?.scheduled_change;
  // If scheduled_change exists with action=cancel → cancel pending; if null → cancel was revoked
  const cancelAtPeriodEnd = scheduledChange?.action === 'cancel' ? 1 : 0;

  const periodStart = data?.current_billing_period?.starts_at
    ? new Date(data.current_billing_period.starts_at).getTime()
    : null;
  const periodEnd = data?.current_billing_period?.ends_at
    ? new Date(data.current_billing_period.ends_at).getTime()
    : null;

  await c.env.DB.prepare(
    `UPDATE subscriptions SET status = ?, cancel_at_period_end = ?,
     current_period_start = COALESCE(?, current_period_start),
     current_period_end = COALESCE(?, current_period_end),
     updated_at = ? WHERE id = ?`
  ).bind(newStatus, cancelAtPeriodEnd, periodStart, periodEnd, now, sub.id).run();

  // If reactivated (was canceling, now active again), ensure tier is pro
  if (newStatus === 'active' && cancelAtPeriodEnd === 0) {
    await c.env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('pro', now, sub.user_id).run();
  }

  try {
    await logSubscriptionEvent(c.env.DB, {
      subscriptionId: sub.id,
      userId: sub.user_id,
      trigger: 'webhook',
      eventType: 'status_changed',
      beforeState,
      afterState: { status: newStatus, cancelAtPeriodEnd: cancelAtPeriodEnd === 1 },
      detail: { webhook_event: event.event_type, scheduled_change: scheduledChange },
    });
  } catch (e) {
    console.error('[Paddle Webhook] Failed to log event:', e);
  }

  console.info(`[Paddle Webhook] Subscription ${subscriptionId} updated: status=${newStatus} cancelAtPeriodEnd=${cancelAtPeriodEnd}`);
}

async function handleSubscriptionCanceled(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  if (!subscriptionId) return;

  const now = Date.now();
  const sub = await c.env.DB.prepare(
    'SELECT id, user_id FROM subscriptions WHERE paddle_subscription_id = ?'
  ).bind(subscriptionId).first<{ id: string; user_id: string }>();

  if (!sub) return;

  await c.env.DB.prepare(
    'UPDATE subscriptions SET status = ?, updated_at = ? WHERE id = ?'
  ).bind('canceled', now, sub.id).run();

  // Check if user has other active subscriptions
  const otherActive = await c.env.DB.prepare(
    "SELECT id FROM subscriptions WHERE user_id = ? AND status IN ('active', 'past_due') AND id != ? LIMIT 1"
  ).bind(sub.user_id, sub.id).first();

  if (!otherActive) {
    await c.env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('free', now, sub.user_id).run();
    console.info(`[Paddle Webhook] User ${sub.user_id} downgraded to free`);
  }
}

async function handleSubscriptionExpired(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  if (!subscriptionId) return;

  const now = Date.now();
  const sub = await c.env.DB.prepare(
    'SELECT id, user_id FROM subscriptions WHERE paddle_subscription_id = ?'
  ).bind(subscriptionId).first<{ id: string; user_id: string }>();

  if (!sub) return;

  await c.env.DB.prepare(
    'UPDATE subscriptions SET status = ?, updated_at = ? WHERE id = ?'
  ).bind('expired', now, sub.id).run();

  const otherActive = await c.env.DB.prepare(
    "SELECT id FROM subscriptions WHERE user_id = ? AND status IN ('active', 'past_due') AND id != ? LIMIT 1"
  ).bind(sub.user_id, sub.id).first();

  if (!otherActive) {
    await c.env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('free', now, sub.user_id).run();
  }
}

async function handleSubscriptionPastDue(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const subscriptionId = data?.id;
  if (!subscriptionId) return;

  const now = Date.now();
  await c.env.DB.prepare(
    'UPDATE subscriptions SET status = ?, updated_at = ? WHERE paddle_subscription_id = ?'
  ).bind('past_due', now, subscriptionId).run();
}

async function handleTransactionCompleted(c: any, event: PaddleWebhookEvent) {
  const data = event.data;
  const transactionId = data?.id;
  const subscriptionId = data?.subscription_id;
  const userId = data?.custom_data?.user_id;

  console.info(`[Paddle Webhook] Transaction completed: ${transactionId}, sub: ${subscriptionId}`);
}

export default paddleWebhooks;