/**
 * Creem Payment Platform Configuration
 *
 * Creem is the Merchant of Record handling payments, tax, and subscriptions.
 * Docs: https://docs.creem.io
 */

export const CREEM_CONFIG = {
  /** Production API */
  prodApiBase: 'https://api.creem.io/v1',
  /** Sandbox / test API */
  testApiBase: 'https://test-api.creem.io/v1',
} as const;

export function getCreemProducts(env: {
  CREEM_PRODUCT_PRO_MONTHLY?: string;
  CREEM_PRODUCT_PRO_YEARLY?: string;
}) {
  return {
    pro_monthly: env.CREEM_PRODUCT_PRO_MONTHLY,
    pro_yearly: env.CREEM_PRODUCT_PRO_YEARLY,
  };
}

/**
 * Map Creem subscription status to internal tier.
 */
export function creemStatusToTier(status: string): 'free' | 'pro' {
  switch (status) {
    case 'active':
    case 'trialing':
    case 'past_due':  // grace period — keep pro until payment truly fails
      return 'pro';
    case 'canceled':
    case 'expired':
    case 'paused':
    default:
      return 'free';
  }
}

/**
 * Resolve the Creem API base URL from environment.
 * Beta/dev → test API, production → live API.
 */
export function getCreemApiBase(environment: string): string {
  return environment === 'production'
    ? CREEM_CONFIG.prodApiBase
    : CREEM_CONFIG.testApiBase;
}
