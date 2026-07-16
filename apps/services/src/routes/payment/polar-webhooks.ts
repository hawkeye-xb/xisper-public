/**
 * Polar Webhook Handler
 *
 * This optional adapter is intentionally fail-closed until provider-specific
 * signature verification is implemented.
 */

import { Hono } from 'hono';

type Bindings = {
  PAYMENT_PROVIDER?: string;
};

const polarWebhooks = new Hono<{ Bindings: Bindings }>();

polarWebhooks.post('/', (c) => {
  if ((c.env.PAYMENT_PROVIDER || 'creem') !== 'polar') {
    return c.json({ error: 'Not Found' }, 404);
  }

  return c.json({ error: 'Polar webhook verification is not configured' }, 503);
});

polarWebhooks.get('/', (c) => {
  const enabled = (c.env.PAYMENT_PROVIDER || 'creem') === 'polar';
  return c.json({ status: enabled ? 'unavailable' : 'disabled', provider: 'polar' });
});

export default polarWebhooks;
