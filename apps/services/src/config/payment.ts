/**
 * Payment Provider Abstraction Layer
 *
 * Abstracts the payment provider (Creem/Polar) to allow switching at runtime.
 */

import type { SubscriptionRow } from '../utils/subscription';

/**
 * Result from creating a checkout session.
 */
export interface CheckoutResult {
  checkout_url: string;
}

/**
 * Result from getting a customer portal URL.
 */
export interface PortalResult {
  portal_url: string;
}

/**
 * Subscription status from provider API.
 */
export interface ProviderSubscriptionStatus {
  status: string;
  current_period_start?: number;
  current_period_end?: number;
  cancel_at_period_end: boolean;
  plan?: string;
}

/**
 * Payment provider interface.
 *
 * Each provider (Creem/Polar) implements this interface.
 */
export interface PaymentProvider {
  /**
   * Provider name for logging and source field.
   */
  readonly source: 'creem' | 'polar' | 'paddle';

  /**
   * Create a checkout session for the user.
   */
  createCheckout(params: {
    productId: string;
    userId: string;
    userEmail?: string;
    successUrl: string;
  }): Promise<CheckoutResult>;

  /**
   * Cancel a subscription at period end.
   */
  cancelSubscription(subscriptionId: string): Promise<void>;

  /**
   * Reactivate a subscription that was scheduled for cancellation.
   * Not all providers support this — returns false if unsupported.
   */
  reactivateSubscription?(subscriptionId: string): Promise<void>;

  /**
   * Get the customer billing portal URL.
   */
  getPortalUrl(customerId: string): Promise<PortalResult>;

  /**
   * Get current subscription status from provider.
   */
  getSubscriptionStatus(subscriptionId: string): Promise<ProviderSubscriptionStatus>;

  /**
   * Map provider status to internal tier.
   */
  statusToTier(status: string): 'free' | 'pro';
}

/**
 * Get the current payment provider based on environment.
 */
export function getPaymentProvider(
  env: {
    PAYMENT_PROVIDER?: string;
    CREEM_API_KEY?: string;
    POLAR_ACCESS_TOKEN?: string;
    PADDLE_ACCESS_TOKEN?: string;
    PADDLE_VENDOR_ID?: string;
    CREEM_PRODUCT_PRO_MONTHLY?: string;
    CREEM_PRODUCT_PRO_YEARLY?: string;
    POLAR_PRODUCT_PRO_MONTHLY?: string;
    PADDLE_PRICE_PRO_MONTHLY?: string;
    POLAR_SERVER?: string;
    ENVIRONMENT?: string;
  },
  logger?: { info: (msg: string) => void; warn: (msg: string) => void }
): PaymentProvider {
  const provider = env.PAYMENT_PROVIDER || 'creem';

  if (logger?.info) {
    logger.info(`[Payment] Using provider: ${provider}`);
  }

  // Lazy imports to avoid loading unused providers
  switch (provider) {
    case 'paddle':
      if (!env.PADDLE_ACCESS_TOKEN) {
        throw new Error('PADDLE_ACCESS_TOKEN is required when PAYMENT_PROVIDER=paddle');
      }
      return createPaddleProvider(env.PADDLE_ACCESS_TOKEN, env.PADDLE_VENDOR_ID, env.ENVIRONMENT, getPaddleProducts(env));

    case 'polar':
      if (!env.POLAR_ACCESS_TOKEN) {
        throw new Error('POLAR_ACCESS_TOKEN is required when PAYMENT_PROVIDER=polar');
      }
      return createPolarProvider(env.POLAR_ACCESS_TOKEN, getPolarProducts(env), env.POLAR_SERVER);

    case 'creem':
    default:
      if (!env.CREEM_API_KEY) {
        throw new Error('CREEM_API_KEY is required when PAYMENT_PROVIDER=creem');
      }
      return createCreemProvider(env.CREEM_API_KEY, env.ENVIRONMENT, getCreemProducts(env));
  }
}

// ============================================
// Creem Provider Implementation
// ============================================

import { getCreemProducts, getCreemApiBase } from './creem';

function createCreemProvider(
  apiKey: string,
  environment = 'development',
  products: ReturnType<typeof getCreemProducts> = {
    pro_monthly: undefined,
    pro_yearly: undefined,
  }
): PaymentProvider {
  return {
    source: 'creem',

    async createCheckout(params) {
      const productId = products[params.productId as keyof typeof products];
      if (!productId) {
        throw new Error(`Unknown product: ${params.productId}`);
      }

      const creemBase = getCreemApiBase(environment);
      const response = await fetch(`${creemBase}/checkouts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
        },
        body: JSON.stringify({
          product_id: productId,
          success_url: params.successUrl,
          request_id: crypto.randomUUID(),
          metadata: {
            user_id: params.userId,
            email: params.userEmail || '',
          },
        }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Creem checkout failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { checkout_url?: string };
      if (!data.checkout_url) {
        throw new Error('Creem response missing checkout_url');
      }

      return { checkout_url: data.checkout_url };
    },

    async cancelSubscription(subscriptionId) {
      const creemBase = getCreemApiBase(environment);
      const response = await fetch(`${creemBase}/subscriptions/${subscriptionId}/cancel`, {
        method: 'POST',
        headers: { 'x-api-key': apiKey },
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Creem cancel failed: ${response.status} ${err}`);
      }
    },

    async getPortalUrl(customerId) {
      const creemBase = getCreemApiBase(environment);
      const response = await fetch(`${creemBase}/customers/billing`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
        },
        body: JSON.stringify({ customer_id: customerId }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Creem portal failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { customer_portal_link?: string };
      if (!data.customer_portal_link) {
        throw new Error('Creem response missing customer_portal_link');
      }

      return { portal_url: data.customer_portal_link };
    },

    async getSubscriptionStatus(subscriptionId) {
      const creemBase = getCreemApiBase(environment);
      const response = await fetch(`${creemBase}/subscriptions/${subscriptionId}`, {
        headers: { 'x-api-key': apiKey },
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Creem status failed: ${response.status} ${err}`);
      }

      const data = await response.json() as {
        status?: string;
        current_period_start?: number;
        current_period_end?: number;
        cancel_at_period_end?: boolean;
      };

      return {
        status: data.status || 'unknown',
        current_period_start: data.current_period_start,
        current_period_end: data.current_period_end,
        cancel_at_period_end: data.cancel_at_period_end || false,
      };
    },

    statusToTier(status: string): 'free' | 'pro' {
      switch (status) {
        case 'active':
        case 'trialing':
        case 'past_due':
          return 'pro';
        case 'canceled':
        case 'expired':
        case 'paused':
        default:
          return 'free';
      }
    },
  };
}

// ============================================
// Polar Provider Implementation
// ============================================

import { getPolarProducts, getPolarApiBase } from './polar';

function createPolarProvider(
  accessToken: string,
  products: ReturnType<typeof getPolarProducts>,
  server = 'sandbox'
): PaymentProvider {

  return {
    source: 'polar',

    async createCheckout(params) {
      const productId = products[params.productId as keyof typeof products];
      if (!productId) {
        throw new Error(`Unknown product: ${params.productId}`);
      }

      const polarBase = getPolarApiBase(server);
      const response = await fetch(`${polarBase}/checkouts`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          products: [{ product_id: productId, quantity: 1 }],
          success_url: params.successUrl,
          customer_email: params.userEmail,
          metadata: {
            user_id: params.userId,
          },
        }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Polar checkout failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { url?: string };
      if (!data.url) {
        throw new Error('Polar response missing url');
      }

      return { checkout_url: data.url };
    },

    async cancelSubscription(subscriptionId) {
      const polarBase = getPolarApiBase(server);
      const response = await fetch(`${polarBase}/subscriptions/${subscriptionId}/cancel`, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${accessToken}` },
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Polar cancel failed: ${response.status} ${err}`);
      }
    },

    async getPortalUrl(_customerId) {
      // Polar uses customer ID differently, need to create a portal session
      const polarBase = getPolarApiBase(server);
      const response = await fetch(`${polarBase}/checkout/sessions/portal`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          customer_id: _customerId,
        }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Polar portal failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { url?: string };
      if (!data.url) {
        throw new Error('Polar response missing url');
      }

      return { portal_url: data.url };
    },

    async getSubscriptionStatus(subscriptionId) {
      const polarBase = getPolarApiBase(server);
      const response = await fetch(`${polarBase}/subscriptions/${subscriptionId}`, {
        headers: { 'Authorization': `Bearer ${accessToken}` },
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Polar status failed: ${response.status} ${err}`);
      }

      const data = await response.json() as {
        status?: string;
        current_period_start?: number;
        current_period_end?: number;
        cancel_at_period_end?: boolean;
        price?: { product?: { name?: string } };
      };

      return {
        status: data.status || 'unknown',
        current_period_start: data.current_period_start,
        current_period_end: data.current_period_end,
        cancel_at_period_end: data.cancel_at_period_end || false,
        plan: data.price?.product?.name,
      };
    },

    statusToTier(status: string): 'free' | 'pro' {
      switch (status) {
        case 'active':
        case 'trialing':
        case 'past_due':
          return 'pro';
        case 'canceled':
        case 'expired':
        case 'paused':
        case 'unpaid':
        default:
          return 'free';
      }
    },
  };
}

/**
 * Get the payment provider for server-side use.
 * This is called in routes with access to env bindings.
 */
export function createPaymentProvider(env: {
  PAYMENT_PROVIDER?: string;
  CREEM_API_KEY?: string;
  POLAR_ACCESS_TOKEN?: string;
  PADDLE_ACCESS_TOKEN?: string;
  PADDLE_VENDOR_ID?: string;
  CREEM_PRODUCT_PRO_MONTHLY?: string;
  CREEM_PRODUCT_PRO_YEARLY?: string;
  POLAR_PRODUCT_PRO_MONTHLY?: string;
  PADDLE_PRICE_PRO_MONTHLY?: string;
  POLAR_SERVER?: string;
  ENVIRONMENT?: string;
}): PaymentProvider {
  return getPaymentProvider(env, {
    info: (msg) => console.log(msg),
    warn: (msg) => console.warn(msg),
  });
}

// ============================================
// Paddle Provider Implementation
// ============================================

import { getPaddleProducts, getPaddleApiBase } from './paddle';

function createPaddleProvider(
  accessToken: string,
  vendorId?: string,
  environment = 'sandbox',
  products: ReturnType<typeof getPaddleProducts> = { pro_monthly: undefined }
): PaymentProvider {
  return {
    source: 'paddle',

    async createCheckout(params) {
      const priceId = products[params.productId as keyof typeof products];
      if (!priceId) {
        throw new Error(`Unknown product: ${params.productId}`);
      }

      const paddleBase = getPaddleApiBase(environment);

      // Create a transaction via Paddle API — response includes hosted checkout URL
      const response = await fetch(`${paddleBase}/transactions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({
          items: [{ price_id: priceId, quantity: 1 }],
          custom_data: {
            user_id: params.userId,
            email: params.userEmail,
          },
        }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Paddle checkout failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { data?: { checkout?: { url?: string } } };
      if (!data?.data?.checkout?.url) {
        throw new Error('Paddle response missing checkout url');
      }

      return { checkout_url: data.data.checkout.url };
    },

    async cancelSubscription(subscriptionId) {
      const paddleBase = getPaddleApiBase(environment);
      const response = await fetch(`${paddleBase}/subscriptions/${subscriptionId}/cancel`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ effective_from: 'next_billing_period' }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Paddle cancel failed: ${response.status} ${err}`);
      }
    },

    async reactivateSubscription(subscriptionId) {
      const paddleBase = getPaddleApiBase(environment);
      // PATCH subscription with scheduled_change: null removes the pending cancellation
      const response = await fetch(`${paddleBase}/subscriptions/${subscriptionId}`, {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ scheduled_change: null }),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Paddle reactivate failed: ${response.status} ${err}`);
      }
    },

    async getPortalUrl(customerId) {
      const paddleBase = getPaddleApiBase(environment);
      const response = await fetch(`${paddleBase}/customers/${customerId}/portal-sessions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`,
        },
        body: JSON.stringify({}),
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Paddle portal failed: ${response.status} ${err}`);
      }

      const data = await response.json() as { data?: { urls?: { general?: { overview?: string } } } };
      const portalUrl = data?.data?.urls?.general?.overview || '';
      return { portal_url: portalUrl };
    },

    async getSubscriptionStatus(subscriptionId) {
      const paddleBase = getPaddleApiBase(environment);
      const response = await fetch(`${paddleBase}/subscriptions/${subscriptionId}`, {
        headers: { 'Authorization': `Bearer ${accessToken}` },
      });

      if (!response.ok) {
        const err = await response.text();
        throw new Error(`Paddle status failed: ${response.status} ${err}`);
      }

      const data = await response.json() as {
        data?: {
          status?: string;
          current_billing_period?: { starts_at?: number; ends_at?: number };
          cancel_at_period_end?: boolean;
        };
      };

      return {
        status: data?.data?.status || 'unknown',
        current_period_start: data?.data?.current_billing_period?.starts_at,
        current_period_end: data?.data?.current_billing_period?.ends_at,
        cancel_at_period_end: data?.data?.cancel_at_period_end || false,
      };
    },

    statusToTier(status: string): 'free' | 'pro' {
      switch (status) {
        case 'active':
        case 'trialing':
        case 'past_due':
          return 'pro';
        case 'canceled':
        case 'expired':
        case 'paused':
        case 'deletion_in_progress':
        default:
          return 'free';
      }
    },
  };
}
