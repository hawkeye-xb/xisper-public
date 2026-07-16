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

export function getPaddleProducts(env: { PADDLE_PRICE_PRO_MONTHLY?: string }) {
  return { pro_monthly: env.PADDLE_PRICE_PRO_MONTHLY };
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
