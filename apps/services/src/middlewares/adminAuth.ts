import { Context, Next } from 'hono';
import { HTTPException } from 'hono/http-exception';
import { jwtVerify } from 'jose';

/**
 * Admin authentication middleware.
 * Verifies admin JWT signed with ADMIN_JWT_SECRET (HMAC-SHA256).
 * Completely independent from Logto auth.
 *
 * After this middleware runs:
 *   - c.get('adminId') → admin account ID
 *   - c.get('adminUsername') → admin username
 */
export async function adminAuthMiddleware(c: Context, next: Next) {
  const authHeader = c.req.header('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    throw new HTTPException(401, { message: 'Admin authentication required' });
  }

  const token = authHeader.substring(7);
  const secret = (c.env as any).ADMIN_JWT_SECRET as string | undefined;

  if (!secret) {
    console.error('[AdminAuth] ADMIN_JWT_SECRET not configured');
    throw new HTTPException(500, { message: 'Server configuration error' });
  }

  try {
    const secretKey = new TextEncoder().encode(secret);
    const { payload } = await jwtVerify(token, secretKey, {
      algorithms: ['HS256'],
    });

    if (payload.role !== 'admin') {
      throw new HTTPException(403, { message: 'Admin access required' });
    }

    c.set('adminId', payload.sub);
    c.set('adminUsername', payload.username);
    await next();
  } catch (error: any) {
    if (error instanceof HTTPException) throw error;
    if (error?.code === 'ERR_JWT_EXPIRED') {
      throw new HTTPException(401, { message: 'Token expired' });
    }
    throw new HTTPException(401, { message: 'Invalid admin token' });
  }
}
