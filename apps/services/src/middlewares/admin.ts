import { Context, Next } from 'hono';
import { HTTPException } from 'hono/http-exception';

/**
 * Admin authorization middleware.
 * Must be used AFTER authMiddleware (requires userId in context).
 *
 * Checks the user's role in D1 database.
 * Returns 403 if the user is not an admin.
 *
 * After this middleware runs, the following context variable is available:
 *   - c.get('userRole') → 'admin'
 */
export async function adminMiddleware(c: Context, next: Next) {
  const userId = c.get('userId');

  if (!userId) {
    throw new HTTPException(401, { message: 'User not authenticated' });
  }

  try {
    const user = await c.env.DB.prepare(
      'SELECT role FROM users WHERE id = ?'
    ).bind(userId).first<{ role: string }>();

    if (!user || user.role !== 'admin') {
      throw new HTTPException(403, { message: 'Admin access required' });
    }

    c.set('userRole', user.role);
    await next();
  } catch (error: any) {
    if (error instanceof HTTPException) throw error;
    console.error('[Admin] Role check failed:', error);
    // Return 403 so frontend shows "Access Denied", not 500 server error
    throw new HTTPException(403, { message: 'Admin access required' });
  }
}
