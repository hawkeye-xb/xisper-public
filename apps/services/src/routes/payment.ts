import { Hono } from 'hono';
import { authMiddleware } from '../middlewares/auth';
import { resolveUserTier } from '../utils/subscription';
import { reconcileSubscription } from '../utils/reconcile';
import { logSubscriptionEvent } from '../utils/subscription-event';
import type { SubscriptionRow } from '../utils/subscription';
import { createPaymentProvider, type PaymentProvider } from '../config/payment';
import { getPaddleProducts, getPaddleApiBase } from '../config/paddle';

type Bindings = {
  AI_KV: KVNamespace;
  DB: D1Database;
  CREEM_API_KEY?: string;
  POLAR_ACCESS_TOKEN?: string;
  PADDLE_ACCESS_TOKEN?: string;
  PADDLE_VENDOR_ID?: string;
  PAYMENT_WEBHOOK_SECRET?: string;
  POLAR_WEBHOOK_SECRET?: string;
  PADDLE_WEBHOOK_SECRET?: string;
  PADDLE_CLIENT_TOKEN?: string;
  ENVIRONMENT: string;
  SERVICE_BASE_URL?: string;
  PAYMENT_PROVIDER?: string;
  POLAR_SERVER?: string;
  PADDLE_SERVER?: string;
  CREEM_PRODUCT_PRO_MONTHLY?: string;
  CREEM_PRODUCT_PRO_YEARLY?: string;
  POLAR_PRODUCT_PRO_MONTHLY?: string;
  PADDLE_PRICE_PRO_MONTHLY?: string;
};

const payment = new Hono<{ Bindings: Bindings }>();

// ============================================
// POST /checkout/create — Create checkout (redirects to Polar)
// ============================================
payment.post('/checkout/create', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;
  const userEmail = c.get('userEmail') as string | undefined;

  const currentTier = await resolveUserTier(c.env.DB, userId);
  if (currentTier !== 'free') {
    return c.json({ success: false, error: 'Already subscribed', currentTier }, 400);
  }

  // Check for existing active subscription
  const existing = await c.env.DB.prepare(
    "SELECT id FROM subscriptions WHERE user_id = ? AND status IN ('active', 'trialing', 'past_due') LIMIT 1"
  ).bind(userId).first();

  if (existing) {
    return c.json({ success: false, error: 'Active subscription already exists' }, 400);
  }

  const provider = getProvider(c);
  console.info(`[Payment] Using provider: ${provider.source} for checkout`);

  // If using Polar, redirect to Polar checkout page
  if (provider.source === 'polar') {
    try {
      if (!c.env.POLAR_PRODUCT_PRO_MONTHLY) {
        return c.json({ success: false, error: 'Polar product is not configured' }, 503);
      }
      // Call Polar API directly to create checkout
      const polarApiBase = 'https://api.polar.sh/v1';
      const polarResponse = await fetch(`${polarApiBase}/checkouts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${c.env.POLAR_ACCESS_TOKEN}`,
        },
        body: JSON.stringify({
          product_id: c.env.POLAR_PRODUCT_PRO_MONTHLY,
          success_url: `${c.env.SERVICE_BASE_URL || 'http://localhost:8787'}/api/v1/payment/success`,
          metadata: { user_id: userId, email: userEmail || '' },
        }),
      });

      if (!polarResponse.ok) {
        const err = await polarResponse.text();
        console.error('[Payment] Polar API error:', polarResponse.status, err);
        throw new Error('Failed to create Polar checkout');
      }

      const checkoutData = await polarResponse.json() as { url?: string; client_secret?: string };
      const checkoutUrl = checkoutData.url || `https://polar.sh/checkout/${checkoutData.client_secret}`;

      return c.json({ success: true, checkout_url: checkoutUrl });
    } catch (err) {
      console.error('[Payment] Polar checkout failed:', err);
      return c.json({ success: false, error: 'Failed to create checkout session' }, 502);
    }
  }

  // If using Paddle, create transaction then return our checkout page URL (embeds Paddle.js)
  if (provider.source === 'paddle') {
    try {
      const paddlePriceId = getPaddleProducts(c.env).pro_monthly;
      if (!paddlePriceId) {
        return c.json({ success: false, error: 'Paddle price is not configured' }, 503);
      }
      const paddleApiBase = getPaddleApiBase(c.env.ENVIRONMENT || 'development');
      const paddleResponse = await fetch(`${paddleApiBase}/transactions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${c.env.PADDLE_ACCESS_TOKEN}`,
        },
        body: JSON.stringify({
          items: [{ price_id: paddlePriceId, quantity: 1 }],
          custom_data: { user_id: userId, email: userEmail || '' },
        }),
      });

      if (!paddleResponse.ok) {
        const err = await paddleResponse.text();
        console.error('[Payment] Paddle API error:', paddleResponse.status, err);
        throw new Error('Failed to create Paddle transaction');
      }

      const txnData = await paddleResponse.json() as { data?: { id?: string; checkout?: { url?: string } } };
      const checkoutUrl = txnData?.data?.checkout?.url;

      if (!checkoutUrl) {
        throw new Error('Paddle response missing checkout url');
      }

      return c.json({ success: true, checkout_url: checkoutUrl });
    } catch (err) {
      console.error('[Payment] Paddle checkout failed:', err);
      return c.json({ success: false, error: 'Failed to create checkout session' }, 502);
    }
  }

  // Fallback to Creem
  const body = await c.req.json().catch(() => ({}));
  const productKey = (body.product as string) || 'pro_monthly';

  const serviceBase = c.env.SERVICE_BASE_URL || 'http://localhost:8787';
  const successUrl = `${serviceBase}/api/v1/payment/success`;

  try {
    const result = await provider.createCheckout({
      productId: productKey,
      userId,
      userEmail,
      successUrl,
    });

    return c.json({ success: true, checkout_url: result.checkout_url });
  } catch (err) {
    console.error('[Payment] Checkout creation failed:', err);
    return c.json({ success: false, error: 'Failed to create checkout session' }, 502);
  }
});

// ============================================
// GET /paddle/checkout — Lightweight page that loads Paddle.js overlay
// Same role as Creem/Polar hosted checkout: user pays here, then redirect to success.
// ============================================
payment.get('/paddle/checkout', async (c) => {
  const txnId = c.req.query('txn');
  if (!txnId) {
    return c.text('Missing transaction ID', 400);
  }

  const env = c.env.ENVIRONMENT || 'development';
  const isSandbox = env !== 'production';
  const clientToken = c.env.PADDLE_CLIENT_TOKEN || '';
  const serviceBase = c.env.SERVICE_BASE_URL || 'http://localhost:8787';
  const successUrl = `${serviceBase}/api/v1/payment/success`;
  const paddleJs = isSandbox
    ? 'https://sandbox-cdn.paddle.com/paddle/v2/paddle.js'
    : 'https://cdn.paddle.com/paddle/v2/paddle.js';

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Checkout — Xisper</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; background: #0a0a0a; color: #e5e5e5;
    }
    .card {
      text-align: center; padding: 48px; border-radius: 16px;
      background: #171717; border: 1px solid #262626; max-width: 420px;
    }
    .spinner { width: 32px; height: 32px; border: 3px solid #333; border-top-color: #008f9f;
      border-radius: 50%; animation: spin 0.8s linear infinite; margin: 0 auto 16px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    h1 { font-size: 20px; font-weight: 600; margin-bottom: 8px; color: #fff; }
    p { font-size: 14px; color: #a3a3a3; }
    .error { color: #ef4444; margin-top: 12px; display: none; }
  </style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>Loading checkout…</h1>
    <p>Preparing your secure payment</p>
    <p class="error" id="err"></p>
  </div>
  <script src="${paddleJs}"></script>
  <script>
    try {
      ${isSandbox ? 'Paddle.Environment.set("sandbox");' : ''}
      Paddle.Initialize({
        token: "${clientToken}",
        checkout: {
          settings: {
            successUrl: "${successUrl}",
            displayMode: "overlay"
          }
        },
        eventCallback: function(ev) {
          if (ev.name === "checkout.closed") {
            // User closed without paying — go back or show message
            document.querySelector("h1").textContent = "Checkout cancelled";
            document.querySelector("p").textContent = "You can close this tab.";
            document.querySelector(".spinner").style.display = "none";
          }
        }
      });
      Paddle.Checkout.open({ transactionId: "${txnId}" });
    } catch(e) {
      document.getElementById("err").style.display = "block";
      document.getElementById("err").textContent = "Failed to load checkout: " + e.message;
    }
  </script>
</body>
</html>`;

  return c.html(html);
});

// ============================================
// GET /payment/success — Landing page after successful payment
// ============================================
payment.get('/payment/success', async (c) => {
  const env = c.env.ENVIRONMENT || 'development';
  const scheme = env === 'production' ? 'xisper-mac' : 'xisper-mac-beta';
  const deepLink = `${scheme}://payment-success`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Payment Successful — Xisper</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex; align-items: center; justify-content: center;
      min-height: 100vh; background: #0a0a0a; color: #e5e5e5;
    }
    .card {
      text-align: center; padding: 48px; border-radius: 16px;
      background: #171717; border: 1px solid #262626; max-width: 420px;
    }
    .icon { font-size: 48px; margin-bottom: 16px; }
    h1 { font-size: 24px; font-weight: 600; margin-bottom: 8px; color: #fff; }
    p { font-size: 14px; color: #a3a3a3; margin-bottom: 24px; line-height: 1.5; }
    .btn {
      display: inline-block; padding: 10px 24px; border-radius: 8px;
      background: #008f9f; color: #fff; text-decoration: none;
      font-size: 14px; font-weight: 500; transition: background 0.2s;
    }
    .btn:hover { background: #00a8bb; }
    .hint { font-size: 12px; color: #525252; margin-top: 16px; }
  </style>
</head>
<body>
  <div class="card">
    <div class="icon">&#10003;</div>
    <h1>Payment Successful</h1>
    <p>Your Pro subscription is now active. Returning you to Xisper...</p>
    <a class="btn" href="${deepLink}">Open Xisper</a>
    <p class="hint">If the app doesn't open automatically, click the button above.</p>
  </div>
  <script>
    setTimeout(function() { window.location.href = "${deepLink}"; }, 1500);
  </script>
</body>
</html>`;

  return c.html(html);
});

// ============================================
// POST /pricing/ticket — Create a short-lived ticket for pricing page
// Client calls this with Bearer token, gets back an opaque ticket.
// ============================================
payment.post('/pricing/ticket', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;
  const userEmail = c.get('userEmail') as string | undefined;
  const ticket = crypto.randomUUID();

  // Store ticket → user mapping in KV (5 min TTL)
  await c.env.AI_KV.put(
    `pricing_ticket:${ticket}`,
    JSON.stringify({ userId, userEmail }),
    { expirationTtl: 300 }
  );

  return c.json({ success: true, ticket });
});

/**
 * Resolve a pricing ticket from KV. Returns null if expired/invalid.
 */
async function resolveTicket(kv: KVNamespace, ticket: string): Promise<{ userId: string; userEmail?: string } | null> {
  if (!ticket) return null;
  const raw = await kv.get(`pricing_ticket:${ticket}`);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// ============================================
// GET /pricing — Server-hosted pricing page (ticket-based, no JWT in URL)
// ============================================
payment.get('/pricing', async (c) => {
  const ticket = c.req.query('t') || '';
  const ticketData = await resolveTicket(c.env.AI_KV, ticket);

  if (!ticketData) {
    return c.html(`<!DOCTYPE html><html><head><meta charset="UTF-8">
      <title>Session Expired</title>
      <style>body{font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;background:#0a0a0a;color:#e5e5e5;}
      .card{text-align:center;padding:48px;border-radius:16px;background:#171717;border:1px solid #262626;}
      h1{font-size:20px;margin-bottom:8px;}p{font-size:14px;color:#a3a3a3;}</style></head>
      <body><div class="card"><h1>Session Expired</h1><p>Please go back to Xisper and try again.</p></div></body></html>`, 401);
  }

  const userId = ticketData.userId;
  const currentTier = await resolveUserTier(c.env.DB, userId);
  const isSubscribed = currentTier !== 'free';

  const env = c.env.ENVIRONMENT || 'development';
  const serviceBase = c.env.SERVICE_BASE_URL || 'http://localhost:8787';
  const scheme = env === 'production' ? 'xisper-mac' : 'xisper-mac-beta';
  const base = `${serviceBase}/api/v1`;

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="referrer" content="no-referrer">
  <title>Choose Your Plan — Xisper</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      min-height: 100vh; background: #0a0a0a; color: #e5e5e5;
      display: flex; flex-direction: column; align-items: center;
      padding: 48px 24px;
    }
    h1 { font-size: 28px; font-weight: 700; color: #fff; margin-bottom: 8px; text-align: center; }
    .subtitle { font-size: 15px; color: #a3a3a3; margin-bottom: 40px; text-align: center; }
    .plans { display: flex; gap: 20px; max-width: 720px; width: 100%; }
    .plan {
      flex: 1; padding: 32px 24px; border-radius: 16px; border: 1px solid #262626;
      background: #171717; display: flex; flex-direction: column; transition: border-color 0.2s;
      position: relative;
    }
    .plan:hover { border-color: #404040; }
    .plan.highlighted { border-color: #008f9f; }
    .plan.highlighted::after {
      content: 'Best Value'; position: absolute; top: -12px; right: 16px;
      background: #008f9f; color: #fff; font-size: 12px; font-weight: 600;
      padding: 4px 12px; border-radius: 12px;
    }
    .plan-name { font-size: 18px; font-weight: 600; color: #fff; margin-bottom: 12px; }
    .plan-price { font-size: 42px; font-weight: 800; color: #fff; line-height: 1; }
    .plan-period { font-size: 14px; color: #737373; margin-top: 4px; margin-bottom: 4px; }
    .plan-equiv { font-size: 13px; color: #008f9f; margin-bottom: 20px; min-height: 18px; }
    .plan-features { list-style: none; flex: 1; margin-bottom: 24px; }
    .plan-features li {
      font-size: 13px; color: #a3a3a3; padding: 6px 0;
      display: flex; align-items: center; gap: 8px;
    }
    .plan-features li::before { content: '\\2713'; color: #008f9f; font-weight: 600; font-size: 14px; }
    a.plan-btn {
      display: block; width: 100%; padding: 14px; border-radius: 12px; border: none;
      font-size: 15px; font-weight: 600; text-align: center; text-decoration: none;
      transition: all 0.2s;
    }
    a.plan-btn.primary { background: #008f9f; color: #fff; }
    a.plan-btn.primary:hover { background: #00a8bb; }
    a.plan-btn.secondary { background: #262626; color: #e5e5e5; }
    a.plan-btn.secondary:hover { background: #333; }
    .badge-save {
      display: inline-block; background: rgba(0,143,159,0.15); color: #008f9f;
      font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 8px;
      margin-left: 8px;
    }
    .subscribed-msg {
      background: #171717; border: 1px solid #262626; border-radius: 16px;
      padding: 32px; text-align: center; max-width: 480px; width: 100%;
    }
    .subscribed-msg h2 { font-size: 20px; color: #fff; margin-bottom: 8px; }
    .subscribed-msg p { font-size: 14px; color: #a3a3a3; margin-bottom: 20px; }
    .back-link {
      color: #008f9f; text-decoration: none; font-size: 14px; margin-top: 24px;
      display: inline-block;
    }
    .back-link:hover { text-decoration: underline; }
    @media (max-width: 600px) {
      .plans { flex-direction: column; }
      .plan-price { font-size: 36px; }
    }
  </style>
</head>
<body>
  ${isSubscribed ? `
  <div class="subscribed-msg">
    <h2>You're already on Pro</h2>
    <p>Manage your subscription in the billing portal.</p>
    <a class="plan-btn primary" href="${base}/pricing/portal?t=${ticket}" style="max-width:240px;margin:0 auto;">
      Manage Subscription
    </a>
    <br>
    <a class="back-link" href="${scheme}://pricing-close">Back to Xisper</a>
  </div>
  ` : `
  <h1>Choose Your Plan</h1>
  <p class="subtitle">Upgrade to Pro for higher limits and priority support.</p>
  <div class="plans">
    <div class="plan" id="plan-monthly">
      <div class="plan-name">Pro Monthly</div>
      <div class="plan-price">$9.99</div>
      <div class="plan-period">per month</div>
      <div class="plan-equiv">&nbsp;</div>
      <ul class="plan-features">
        <li>13.3 hours of speech recognition per week</li>
        <li>80,000 characters per week</li>
        <li>3,200 AI processing calls per day</li>
        <li>Role-based vocabulary (Developer, Lawyer, Doctor, PM)</li>
        <li>Custom hotwords and corrections</li>
        <li>Priority support</li>
      </ul>
      <a class="plan-btn secondary" href="${base}/pricing/checkout?t=${ticket}&plan=pro_monthly">Subscribe Monthly</a>
    </div>
    <div class="plan highlighted" id="plan-yearly">
      <div class="plan-name">Pro Yearly <span class="badge-save">Save 33%</span></div>
      <div class="plan-price">$79.99</div>
      <div class="plan-period">per year</div>
      <div class="plan-equiv">~$6.67/month</div>
      <ul class="plan-features">
        <li>13.3 hours of speech recognition per week</li>
        <li>80,000 characters per week</li>
        <li>3,200 AI processing calls per day</li>
        <li>Role-based vocabulary (Developer, Lawyer, Doctor, PM)</li>
        <li>Custom hotwords and corrections</li>
        <li>Priority support</li>
      </ul>
      <a class="plan-btn primary" href="${base}/pricing/checkout?t=${ticket}&plan=pro_yearly">Subscribe Yearly</a>
    </div>
  </div>
  <a class="back-link" href="${scheme}://pricing-close">Cancel</a>
  `}
</body>
</html>`;

  return c.html(html);
});

// ============================================
// GET /pricing/checkout — Server-side checkout redirect (ticket-based)
// ============================================
payment.get('/pricing/checkout', async (c) => {
  const ticket = c.req.query('t') || '';
  const plan = c.req.query('plan') || 'pro_monthly';
  const ticketData = await resolveTicket(c.env.AI_KV, ticket);

  if (!ticketData) {
    return c.text('Session expired. Please go back to Xisper and try again.', 401);
  }

  const { userId, userEmail } = ticketData;
  const currentTier = await resolveUserTier(c.env.DB, userId);
  if (currentTier !== 'free') {
    return c.text('You already have an active subscription.', 400);
  }

  const provider = getProvider(c);
  const serviceBase = c.env.SERVICE_BASE_URL || 'http://localhost:8787';
  const successUrl = `${serviceBase}/api/v1/payment/success`;

  try {
    const result = await provider.createCheckout({
      productId: plan,
      userId,
      userEmail,
      successUrl,
    });
    return c.redirect(result.checkout_url);
  } catch (err: any) {
    console.error('[Pricing] Checkout failed:', err);
    return c.text('Failed to create checkout: ' + (err.message || 'Unknown error'), 502);
  }
});

// ============================================
// GET /pricing/portal — Server-side portal redirect (ticket-based)
// ============================================
payment.get('/pricing/portal', async (c) => {
  const ticket = c.req.query('t') || '';
  const ticketData = await resolveTicket(c.env.AI_KV, ticket);

  if (!ticketData) {
    return c.text('Session expired. Please go back to Xisper and try again.', 401);
  }

  const { userId } = ticketData;
  const sub = await c.env.DB.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) {
    return c.text('No subscription found.', 404);
  }

  const provider = getProvider(c);
  const customerId = sub.source === 'creem' ? sub.creem_customer_id :
                     sub.source === 'polar' ? sub.polar_customer_id :
                     sub.source === 'paddle' ? sub.paddle_customer_id : null;

  if (!customerId) {
    return c.text('Billing portal not available — customer ID missing.', 404);
  }

  try {
    const result = await provider.getPortalUrl(customerId);
    return c.redirect(result.portal_url);
  } catch (err: any) {
    console.error('[Pricing] Portal failed:', err);
    return c.text('Billing portal unavailable: ' + (err.message || 'Unknown error'), 502);
  }
});

// ============================================
// POST /webhooks/creem — Creem webhook receiver
// ============================================
payment.post('/webhooks/creem', async (c) => {
  const secret = c.env.PAYMENT_WEBHOOK_SECRET;
  if (!secret) {
    console.error('[Webhook] PAYMENT_WEBHOOK_SECRET not configured');
    return c.json({ error: 'Webhook not configured' }, 500);
  }

  const signature = c.req.header('creem-signature');
  const rawBody = await c.req.text();

  if (!signature) {
    return c.json({ error: 'Missing signature' }, 401);
  }

  const isValid = await verifyCreemSignature(rawBody, signature, secret);
  if (!isValid) {
    return c.json({ error: 'Invalid signature' }, 401);
  }

  let event: CreemWebhookEvent;
  try {
    event = JSON.parse(rawBody);
  } catch {
    return c.json({ error: 'Invalid JSON' }, 400);
  }

  const eventType = event.eventType || event.type;
  console.info(`[Webhook] Received event: ${eventType}`);

  try {
    switch (eventType) {
      case 'checkout.completed':
        await handleCheckoutCompleted(c, event);
        break;
      case 'subscription.active':
      case 'subscription.paid':
        await handleSubscriptionActive(c, event);
        break;
      case 'subscription.canceled':
      case 'subscription.expired':
        await handleSubscriptionEnded(c, event);
        break;
      default:
        console.info(`[Webhook] Unhandled event type: ${eventType}`);
    }
  } catch (err) {
    console.error(`[Webhook] Error handling ${eventType}:`, err);
  }

  return c.json({ received: true });
});

// ============================================
// Polar Webhooks using SDK
// ============================================
import polarWebhooks from './payment/polar-webhooks';

payment.route('/webhooks/polar', polarWebhooks);

// ============================================
// Paddle Webhooks
// ============================================
import paddleWebhooks from './payment/paddle-webhooks';

payment.route('/webhooks/paddle', paddleWebhooks);

// ============================================
// GET /subscription/status
// ============================================
payment.get('/subscription/status', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;

  const sub = await c.env.DB.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) {
    return c.json({
      success: true,
      hasSubscription: false,
      plan: 'free',
      status: null,
    });
  }

  if (sub.source === 'creem' && sub.creem_subscription_id) {
    try {
      const reconciled = await reconcileSubscription(
        c.env.DB, sub, c.env.CREEM_API_KEY, c.env.ENVIRONMENT,
        { force: false, trigger: 'api' },
      );
      if (reconciled) {
        return c.json({
          success: true,
          hasSubscription: true,
          plan: reconciled.plan,
          status: reconciled.status,
          currentPeriodEnd: reconciled.current_period_end,
          cancelAtPeriodEnd: reconciled.cancel_at_period_end === 1,
          source: reconciled.source,
          subscriptionId: sub.creem_subscription_id,
        });
      }
    } catch (err) {
      console.warn('[Payment] Reconciliation failed:', err);
    }
  }

  return c.json({
    success: true,
    hasSubscription: true,
    plan: sub.plan,
    status: sub.status,
    currentPeriodEnd: sub.current_period_end,
    cancelAtPeriodEnd: sub.cancel_at_period_end === 1,
    source: sub.source,
    subscriptionId: sub.source === 'creem' ? sub.creem_subscription_id :
                    sub.source === 'polar' ? sub.polar_subscription_id :
                    sub.source === 'paddle' ? sub.paddle_subscription_id : null,
  });
});

// ============================================
// POST /subscription/cancel
// ============================================
payment.post('/subscription/cancel', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;

  const sub = await c.env.DB.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? AND status = 'active' ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) {
    return c.json({ success: false, error: 'No active subscription found' }, 404);
  }

  const provider = getProvider(c);
  const subscriptionId = sub.source === 'creem' ? sub.creem_subscription_id :
                         sub.source === 'polar' ? sub.polar_subscription_id :
                         sub.source === 'paddle' ? sub.paddle_subscription_id : null;

  if (!subscriptionId) {
    return c.json({ success: false, error: 'No subscription ID found' }, 404);
  }

  try {
    await provider.cancelSubscription(subscriptionId);
  } catch (err) {
    console.error('[Payment] Cancel failed:', err);
    return c.json({ success: false, error: 'Failed to cancel subscription' }, 502);
  }

  const now = Date.now();
  await c.env.DB.prepare(
    'UPDATE subscriptions SET cancel_at_period_end = 1, updated_at = ? WHERE id = ?'
  ).bind(now, sub.id).run();

  return c.json({ success: true, cancelAtPeriodEnd: true });
});

// ============================================
// POST /subscription/reactivate — Undo a scheduled cancellation
// ============================================
payment.post('/subscription/reactivate', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;

  const sub = await c.env.DB.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? AND status = 'active' AND cancel_at_period_end = 1 ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) {
    return c.json({ success: false, error: 'No subscription pending cancellation' }, 404);
  }

  const provider = getProvider(c);
  const subscriptionId = sub.source === 'creem' ? sub.creem_subscription_id :
                         sub.source === 'polar' ? sub.polar_subscription_id :
                         sub.source === 'paddle' ? sub.paddle_subscription_id : null;

  if (!subscriptionId) {
    return c.json({ success: false, error: 'No subscription ID found' }, 404);
  }

  if (!provider.reactivateSubscription) {
    return c.json({ success: false, error: 'Reactivation not supported for this provider' }, 400);
  }

  try {
    await provider.reactivateSubscription(subscriptionId);
  } catch (err) {
    console.error('[Payment] Reactivate failed:', err);
    return c.json({ success: false, error: 'Failed to reactivate subscription' }, 502);
  }

  const now = Date.now();
  await c.env.DB.prepare(
    'UPDATE subscriptions SET cancel_at_period_end = 0, updated_at = ? WHERE id = ?'
  ).bind(now, sub.id).run();

  return c.json({ success: true, cancelAtPeriodEnd: false });
});

// ============================================
// GET /subscription/portal
// ============================================
payment.get('/subscription/portal', authMiddleware, async (c) => {
  const userId = c.get('userId') as string;

  const sub = await c.env.DB.prepare(
    "SELECT * FROM subscriptions WHERE user_id = ? ORDER BY created_at DESC LIMIT 1"
  ).bind(userId).first<SubscriptionRow>();

  if (!sub) {
    return c.json({ success: false, error: 'No subscription found' }, 404);
  }

  const provider = getProvider(c);
  const customerId = sub.source === 'creem' ? sub.creem_customer_id :
                     sub.source === 'polar' ? sub.polar_customer_id :
                     sub.source === 'paddle' ? sub.paddle_customer_id : null;

  if (!customerId) {
    return c.json({ success: false, error: 'No customer ID found' }, 404);
  }

  try {
    const result = await provider.getPortalUrl(customerId);
    return c.json({ success: true, portal_url: result.portal_url });
  } catch (err) {
    console.error('[Payment] Portal failed:', err);
    return c.json({ success: false, error: 'Billing portal unavailable' }, 502);
  }
});

// ============================================
// Helpers
// ============================================

function getProvider(c: any): PaymentProvider {
  return createPaymentProvider({
    PAYMENT_PROVIDER: c.env.PAYMENT_PROVIDER,
    CREEM_API_KEY: c.env.CREEM_API_KEY,
    POLAR_ACCESS_TOKEN: c.env.POLAR_ACCESS_TOKEN,
    PADDLE_ACCESS_TOKEN: c.env.PADDLE_ACCESS_TOKEN,
    PADDLE_VENDOR_ID: c.env.PADDLE_VENDOR_ID,
    CREEM_PRODUCT_PRO_MONTHLY: c.env.CREEM_PRODUCT_PRO_MONTHLY,
    CREEM_PRODUCT_PRO_YEARLY: c.env.CREEM_PRODUCT_PRO_YEARLY,
    POLAR_PRODUCT_PRO_MONTHLY: c.env.POLAR_PRODUCT_PRO_MONTHLY,
    PADDLE_PRICE_PRO_MONTHLY: c.env.PADDLE_PRICE_PRO_MONTHLY,
    POLAR_SERVER: c.env.POLAR_SERVER,
    ENVIRONMENT: c.env.ENVIRONMENT,
  });
}

interface CreemWebhookEvent {
  eventType?: string;
  type?: string;
  object?: any;
  data?: any;
}

function getEventData(event: CreemWebhookEvent) {
  return event.object || event.data || {};
}

async function handleCheckoutCompleted(c: any, event: CreemWebhookEvent) {
  const data = getEventData(event);
  const userId = data.metadata?.user_id;
  if (!userId) return;

  const now = Date.now();
  const subId = data.subscription?.id || null;
  const customerId = data.customer?.id || null;
  const checkoutId = data.id || null;

  const existing = await c.env.DB.prepare(
    'SELECT id FROM subscriptions WHERE creem_checkout_id = ?'
  ).bind(checkoutId).first();

  if (existing) return;

  const id = crypto.randomUUID();
  await c.env.DB.prepare(
    `INSERT INTO subscriptions
       (id, user_id, source, creem_subscription_id, creem_customer_id, creem_checkout_id,
        plan, status, current_period_start, current_period_end, created_at, updated_at)
     VALUES (?, ?, 'creem', ?, ?, ?, 'pro_monthly', 'active', ?, ?, ?, ?)`
  ).bind(
    id, userId, subId, customerId, checkoutId,
    data.subscription?.current_period_start || now,
    data.subscription?.current_period_end || null,
    now, now
  ).run();

  await c.env.DB.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind('pro', now, userId).run();

  console.info(`[Webhook] User ${userId} upgraded to pro (source=creem)`);
}

async function handleSubscriptionActive(c: any, event: CreemWebhookEvent) {
  const data = getEventData(event);
  const subId = data.subscription?.id || data.id;
  if (!subId) return;

  const now = Date.now();
  const sub = await c.env.DB.prepare(
    'SELECT id, user_id FROM subscriptions WHERE creem_subscription_id = ?'
  ).bind(subId).first<{ id: string; user_id: string }>();

  if (!sub) return;

  await c.env.DB.prepare(
    `UPDATE subscriptions SET status = 'active', updated_at = ? WHERE id = ?`
  ).bind(now, sub.id).run();

  await c.env.DB.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind('pro', now, sub.user_id).run();
}

async function handleSubscriptionEnded(c: any, event: CreemWebhookEvent) {
  const data = getEventData(event);
  const subId = data.subscription?.id || data.id;
  if (!subId) return;

  const now = Date.now();
  const eventType = event.eventType || event.type;
  const status = eventType === 'subscription.canceled' ? 'canceled' : 'expired';

  const sub = await c.env.DB.prepare(
    'SELECT id, user_id FROM subscriptions WHERE creem_subscription_id = ?'
  ).bind(subId).first<{ id: string; user_id: string }>();

  if (!sub) return;

  await c.env.DB.prepare(
    'UPDATE subscriptions SET status = ?, updated_at = ? WHERE id = ?'
  ).bind(status, now, sub.id).run();

  const otherActive = await c.env.DB.prepare(
    "SELECT id FROM subscriptions WHERE user_id = ? AND status IN ('active', 'past_due') AND id != ? LIMIT 1"
  ).bind(sub.user_id, sub.id).first();

  if (!otherActive) {
    await c.env.DB.prepare(
      'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
    ).bind('free', now, sub.user_id).run();
  }
}

async function verifyCreemSignature(
  body: string,
  signature: string,
  secret: string
): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    const sig = await crypto.subtle.sign('HMAC', key, encoder.encode(body));
    const expected = Array.from(new Uint8Array(sig))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    if (expected.length !== signature.length) return false;
    let diff = 0;
    for (let i = 0; i < expected.length; i++) {
      diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
    }
    return diff === 0;
  } catch {
    return false;
  }
}

export { reconcileUserSubscription } from '../utils/reconcile';

export default payment;
