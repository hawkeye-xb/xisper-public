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

/**
 * Product ID mapping — separate for sandbox (beta/dev) and live (production).
 */
const CREEM_PRODUCTS_LIVE = {
  pro_monthly: 'prod_6hAeBM1s9mjR0GtvFC7n4j',
  pro_yearly: 'prod_VYsWgRXBE1dDyGvNq8uCb',
} as const;

const CREEM_PRODUCTS_SANDBOX = {
  pro_monthly: 'prod_39f6MsqasslsJVAkjX4Bjq',
  pro_yearly: 'prod_4cIajPNIbxIM550j4MBOgk',
} as const;

export function getCreemProducts(environment: string) {
  return environment === 'production' ? CREEM_PRODUCTS_LIVE : CREEM_PRODUCTS_SANDBOX;
}

/** @deprecated Use getCreemProducts(environment) instead */
export const CREEM_PRODUCTS = CREEM_PRODUCTS_LIVE;

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
