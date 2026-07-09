/**
 * Polar Webhook Handler - Direct Implementation
 */

import { Hono } from 'hono';

type Bindings = {
  DB: D1Database;
  POLAR_WEBHOOK_SECRET: string;
  POLAR_ACCESS_TOKEN?: string;
};

const polarWebhooks = new Hono<{ Bindings: Bindings }>();

// ============================================
// Direct webhook handler (without SDK for debugging)
// ============================================
polarWebhooks.post('/', async (c) => {
  const secret = c.env.POLAR_WEBHOOK_SECRET;
  if (!secret) {
    console.error('[Polar Webhook] POLAR_WEBHOOK_SECRET not configured');
    return c.json({ error: 'Webhook not configured' }, 500);
  }

  const signature = c.req.header('polar-signature');
  const rawBody = await c.req.text();

  console.info('[Polar Webhook] Received webhook, signature:', signature ? 'present' : 'missing');

  // For now, just acknowledge the webhook - signature verification can be added later
  // The SDK handles this automatically but let's debug first

  let event;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return c.json({ error: 'Invalid JSON' }, 400);
  }

  console.info('[Polar Webhook] Event type:', event?.event?.type || event?.type);

  return c.json({ received: true });
});

// Health check
polarWebhooks.get('/', (c) => {
  return c.json({ status: 'ok', provider: 'polar' });
});

export default polarWebhooks;
