import { Hono } from 'hono';
import { SignJWT } from 'jose';
import { hashPassword, verifyPassword } from '../utils/password';
import { adminAuthMiddleware } from '../middlewares/adminAuth';

type Bindings = {
  DB: D1Database;
  ADMIN_JWT_SECRET: string;
  ADMIN_SETUP_SECRET?: string;
};

const adminAuth = new Hono<{ Bindings: Bindings }>();

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  const length = Math.max(leftBytes.length, rightBytes.length);
  let mismatch = leftBytes.length ^ rightBytes.length;

  for (let index = 0; index < length; index++) {
    mismatch |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }

  return mismatch === 0;
}

/**
 * POST /login — Admin username/password login
 * Returns a signed JWT on success.
 */
adminAuth.post('/login', async (c) => {
  const { username, password } = await c.req.json<{ username: string; password: string }>();

  if (!username || !password) {
    return c.json({ success: false, error: 'Username and password required' }, 400);
  }

  const account = await c.env.DB.prepare(
    'SELECT id, username, password_hash FROM admin_accounts WHERE username = ?'
  ).bind(username).first<{ id: string; username: string; password_hash: string }>();

  if (!account) {
    return c.json({ success: false, error: 'Invalid credentials' }, 401);
  }

  const valid = await verifyPassword(password, account.password_hash);
  if (!valid) {
    return c.json({ success: false, error: 'Invalid credentials' }, 401);
  }

  // Sign admin JWT (24h expiry)
  const secretKey = new TextEncoder().encode(c.env.ADMIN_JWT_SECRET);
  const token = await new SignJWT({
    sub: account.id,
    username: account.username,
    role: 'admin',
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('24h')
    .sign(secretKey);

  return c.json({
    success: true,
    token,
    expiresIn: 86400,
    username: account.username,
  });
});

/**
 * POST /setup — Create the initial admin account.
 * Only works when admin_accounts table is empty (first-time setup).
 */
adminAuth.post('/setup', async (c) => {
  const configuredSecret = c.env.ADMIN_SETUP_SECRET;
  if (!configuredSecret) {
    console.error('[Admin Setup] ADMIN_SETUP_SECRET is not configured');
    return c.json({ success: false, error: 'Admin setup is not configured' }, 503);
  }

  const suppliedSecret = c.req.header('X-Admin-Setup-Secret');
  if (!suppliedSecret || !constantTimeEqual(suppliedSecret, configuredSecret)) {
    return c.json({ success: false, error: 'Invalid setup credentials' }, 401);
  }

  const count = await c.env.DB.prepare(
    'SELECT COUNT(*) as cnt FROM admin_accounts'
  ).first<{ cnt: number }>();

  if (count && count.cnt > 0) {
    return c.json({ success: false, error: 'Admin account already exists. Use /change-password to update.' }, 403);
  }

  const { username, password } = await c.req.json<{ username: string; password: string }>();

  if (!username || !password || password.length < 6) {
    return c.json({ success: false, error: 'Username and password (min 6 chars) required' }, 400);
  }

  const id = `admin_${Date.now()}`;
  const passwordHash = await hashPassword(password);
  const now = Date.now();

  await c.env.DB.prepare(
    'INSERT INTO admin_accounts (id, username, password_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
  ).bind(id, username, passwordHash, now, now).run();

  return c.json({ success: true, message: `Admin account "${username}" created` });
});

/**
 * GET /me — Verify current admin session
 */
adminAuth.get('/me', adminAuthMiddleware, async (c) => {
  const ctx = c as any;
  return c.json({
    success: true,
    username: ctx.get('adminUsername'),
    id: ctx.get('adminId'),
  });
});

/**
 * POST /change-password — Change admin password (requires current auth)
 */
adminAuth.post('/change-password', adminAuthMiddleware, async (c) => {
  const { currentPassword, newPassword } = await c.req.json<{
    currentPassword: string;
    newPassword: string;
  }>();

  if (!newPassword || newPassword.length < 6) {
    return c.json({ success: false, error: 'New password must be at least 6 characters' }, 400);
  }

  const adminId = (c as any).get('adminId') as string;
  const account = await c.env.DB.prepare(
    'SELECT password_hash FROM admin_accounts WHERE id = ?'
  ).bind(adminId).first<{ password_hash: string }>();

  if (!account) {
    return c.json({ success: false, error: 'Account not found' }, 404);
  }

  const valid = await verifyPassword(currentPassword, account.password_hash);
  if (!valid) {
    return c.json({ success: false, error: 'Current password is incorrect' }, 401);
  }

  const newHash = await hashPassword(newPassword);
  await c.env.DB.prepare(
    'UPDATE admin_accounts SET password_hash = ?, updated_at = ? WHERE id = ?'
  ).bind(newHash, Date.now(), adminId).run();

  return c.json({ success: true, message: 'Password updated' });
});

export default adminAuth;
