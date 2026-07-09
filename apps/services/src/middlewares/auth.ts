import { Context, Next } from 'hono';
import { getCookie } from 'hono/cookie';
import { HTTPException } from 'hono/http-exception';
import { createRemoteJWKSet, jwtVerify } from 'jose';

/**
 * JWT Payload from Logto
 */
export interface LogtoJWTPayload {
  sub: string;        // User ID
  aud: string;        // Audience
  iss: string;        // Issuer (Logto endpoint)
  exp: number;        // Expiration time
  iat: number;        // Issued at
  email?: string;
  username?: string;
  [key: string]: any;
}

/**
 * Resolve authentication token from request context.
 * Single source of truth for token extraction across all endpoints.
 *
 * Priority: Authorization header > Cookie > Query parameter
 *
 * - Authorization header: standard for HTTP requests (added by frontend fetch interceptor)
 * - Cookie: backward compatibility
 * - Query parameter: WebSocket connections (WebSocket API doesn't support custom headers)
 */
export function resolveToken(c: Context): string | null {
  // 1. Authorization header (preferred for HTTP requests)
  const authHeader = c.req.header('Authorization');
  if (authHeader?.startsWith('Bearer ')) {
    return authHeader.substring(7);
  }

  // 2. Cookie (backward compatibility)
  const cookieToken = getCookie(c, 'auth_token');
  if (cookieToken) {
    return cookieToken;
  }

  // 3. Query parameter (for WebSocket connections)
  const queryToken = c.req.query('token');
  if (queryToken) {
    return queryToken;
  }

  return null;
}

// JWKS keyset cache (persists across requests within the same Worker isolate)
let cachedJWKS: ReturnType<typeof createRemoteJWKSet> | null = null;
let cachedEndpoint: string | null = null;

function getJWKS(logtoEndpoint: string) {
  if (cachedJWKS && cachedEndpoint === logtoEndpoint) {
    return cachedJWKS;
  }
  const jwksUri = new URL('/oidc/jwks', logtoEndpoint);
  cachedJWKS = createRemoteJWKSet(jwksUri);
  cachedEndpoint = logtoEndpoint;
  return cachedJWKS;
}

/**
 * Verify JWT token using Logto's JWKS endpoint.
 * Validates signature, issuer, audience, and expiration.
 *
 * In development mode, falls back to decodeJWT (no signature verification)
 * when JWKS fetch fails due to network issues, so local dev is not blocked.
 */
export async function verifyJWT(
  token: string,
  env: { LOGTO_ENDPOINT: string; LOGTO_APP_ID?: string; ENVIRONMENT?: string }
): Promise<LogtoJWTPayload> {
  const endpoint = env.LOGTO_ENDPOINT.replace(/\/+$/, '');
  const jwks = getJWKS(endpoint);
  const issuer = `${endpoint}/oidc`;

  try {
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      audience: env.LOGTO_APP_ID || undefined,
    });

    if (!payload.sub) {
      throw new Error('Invalid token: missing sub claim');
    }

    return payload as unknown as LogtoJWTPayload;
  } catch (error: any) {
    // In development: fallback to decode-only when JWKS is unreachable
    const isDev = !env.ENVIRONMENT || env.ENVIRONMENT === 'development';
    const isNetworkError = error?.code === 'ERR_JOSE_GENERIC' || error?.message?.includes('fetch');

    if (isDev && isNetworkError) {
      console.warn('[Auth] JWKS unreachable, falling back to decodeJWT (dev only)');
      const payload = decodeJWT(token);
      if (!payload.sub) {
        throw new Error('Invalid token: missing sub claim');
      }
      return payload;
    }

    throw error;
  }
}

/**
 * Decode JWT payload without signature verification.
 * Only used for reading payload from freshly-issued tokens (e.g. after token exchange).
 */
export function decodeJWT(token: string): LogtoJWTPayload {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) {
      throw new Error('Invalid JWT format');
    }

    const payload = parts[1];
    const decoded = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(decoded);
  } catch (error) {
    throw new Error('Failed to decode JWT');
  }
}

/**
 * Unified authentication middleware.
 *
 * Resolves token → decodes JWT → validates claims → syncs user to DB → sets context.
 * Use this as route-level middleware for all protected endpoints.
 *
 * After this middleware runs, the following context variables are available:
 *   - c.get('userId')     → string
 *   - c.get('userEmail')  → string | undefined
 *   - c.get('jwtPayload') → LogtoJWTPayload
 */
export async function authMiddleware(c: Context, next: Next) {
  const token = resolveToken(c);

  if (!token) {
    throw new HTTPException(401, {
      message: 'Missing authentication token',
    });
  }

  try {
    const payload = await verifyJWT(token, c.env);

    // Store user info in context
    c.set('userId', payload.sub);
    c.set('userEmail', payload.email);
    c.set('jwtPayload', payload);

    // Sync user to database if first time
    await syncUserToDatabase(c, payload);

    await next();
  } catch (error: any) {
    console.error('Auth error:', error);
    throw new HTTPException(401, {
      message: error.message || 'Invalid or expired token',
    });
  }
}

/**
 * Sync Logto user to local database
 */
async function syncUserToDatabase(c: Context, payload: LogtoJWTPayload) {
  try {
    const userId = payload.sub;
    const email = payload.email || '';
    const timestamp = Date.now();

    // 1. Check if user exists by id
    const existingById = await c.env.DB.prepare(
      'SELECT id, email FROM users WHERE id = ?'
    ).bind(userId).first<{ id: string; email: string | null }>();

    if (existingById) {
      // User exists by id — update email if JWT provides one
      const emailToSet = email || existingById.email || '';
      await c.env.DB.prepare(
        'UPDATE users SET email = ?, updated_at = ? WHERE id = ?'
      ).bind(emailToSet, timestamp, userId).run();
      return;
    }

    // 2. User not found by id — check if email already exists (different Logto sub, same person)
    if (email) {
      const existingByEmail = await c.env.DB.prepare(
        'SELECT id, email FROM users WHERE email = ?'
      ).bind(email).first<{ id: string; email: string | null }>();

      if (existingByEmail) {
        // Same email, different sub — update the existing row's id to the new sub
        // This merges the account: old sub's data now belongs to new sub
        await c.env.DB.prepare(
          'UPDATE users SET id = ?, updated_at = ? WHERE email = ?'
        ).bind(userId, timestamp, email).run();
        console.info(`[Auth] Merged user: old=${existingByEmail.id} → new=${userId} (email=${email})`);
        return;
      }
    }

    // 3. Completely new user — insert
    await c.env.DB.prepare(
      'INSERT INTO users (id, email, tier, created_at, updated_at, metadata) VALUES (?, ?, ?, ?, ?, ?)'
    ).bind(
      userId,
      email,
      'free',
      timestamp,
      timestamp,
      JSON.stringify({ source: 'logto', firstLogin: timestamp })
    ).run();

    console.info(`[Auth] New user synced: ${userId}`);
  } catch (error) {
    console.error('Failed to sync user to database:', error);
    // Don't throw - auth should still succeed even if DB sync fails
  }
}

/**
 * Optional: Middleware to check if user has quota remaining
 */
export async function quotaCheckMiddleware(c: Context, next: Next) {
  const userId = c.get('userId');
  
  if (!userId) {
    throw new HTTPException(401, { message: 'User not authenticated' });
  }

  // Get user tier from database
  const user = await c.env.DB.prepare(
    'SELECT tier FROM users WHERE id = ?'
  ).bind(userId).first();

  const tier = (user?.tier as string) || 'free';
  const limits: Record<string, number> = {
    free: 100,
    pro: 1000,
    vip: 10000,
  };

  const limit = limits[tier] || 100;

  // Check current usage from KV
  const quotaKey = `quota:${userId}`;
  const currentUsage = await c.env.AI_KV.get(quotaKey);
  const usage = parseInt(currentUsage || '0');

  if (usage >= limit) {
    throw new HTTPException(429, {
      message: 'Quota exceeded',
      cause: {
        currentUsage: usage,
        limit,
        tier,
      },
    });
  }

  // Store quota info in context for later use
  c.set('currentUsage', usage);
  c.set('quotaLimit', limit);
  c.set('userTier', tier);

  await next();
}
