/**
 * Paddle Payment Platform Configuration
 *
 * Paddle is a merchant of record that handles payments, subscriptions, and tax.
 * Docs: https://developer.paddle.com
 */

export const PADDLE_CONFIG = {
  /** Production API */
  prodApiBase: 'https://api.paddle.com',
  /** Sandbox API */
  sandboxApiBase: 'https://sandbox-api.paddle.com',
} as const;

/**
 * Product/Price ID mapping — separate for sandbox and live
 * Created in Paddle Dashboard → Catalog → Products
 */
const PADDLE_PRODUCTS_LIVE = {
  pro_monthly: 'pri_01knh90kgs1h8qg4h6wgrcpnxj',
} as const;

const PADDLE_PRODUCTS_SANDBOX = {
  pro_monthly: 'pri_01knkehsb275472d2bmq4rq4dq',
} as const;

export function getPaddleProducts(environment: string) {
  return environment === 'production' ? PADDLE_PRODUCTS_LIVE : PADDLE_PRODUCTS_SANDBOX;
}

/**
 * Map Paddle subscription status to internal tier.
 */
export function paddleStatusToTier(status: string): 'free' | 'pro' {
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
}

/**
 * Resolve the Paddle API base URL from environment.
 */
export function getPaddleApiBase(environment: string): string {
  return environment === 'production'
    ? PADDLE_CONFIG.prodApiBase
    : PADDLE_CONFIG.sandboxApiBase;
}