/**
 * Polar Payment Platform Configuration
 *
 * Polar is a developer-friendly payment platform.
 * Docs: https://polar.sh/docs
 */

export const POLAR_CONFIG = {
  /** Production API */
  prodApiBase: 'https://api.polar.sh/v1',
  /** Sandbox / test API */
  sandboxApiBase: 'https://sandbox.api.polar.sh/v1',
} as const;

/**
 * Product ID mapping — fill in after creating products in Polar Dashboard.
 *
 * Format: UUID (e.g., 860d52db-50c3-484b-9122-df51a559b439)
 */
export const POLAR_PRODUCTS = {
  pro_monthly: '769294e3-8d72-46df-a405-5a7bf22ff00a',
} as const;

/**
 * Map Polar subscription status to internal tier.
 *
 * Polar statuses: https://polar.sh/docs/guides/subscriptions#subscription-states
 */
export function polarStatusToTier(status: string): 'free' | 'pro' {
  switch (status) {
    case 'active':
    case 'trialing':
    case 'past_due':  // grace period — keep pro until payment truly fails
      return 'pro';
    case 'canceled':
    case 'expired':
    case 'paused':
    case 'unpaid':
    default:
      return 'free';
  }
}

/**
 * Resolve the Polar API base URL from environment.
 */
export function getPolarApiBase(server: string): string {
  return server === 'production'
    ? POLAR_CONFIG.prodApiBase
    : POLAR_CONFIG.sandboxApiBase;
}
