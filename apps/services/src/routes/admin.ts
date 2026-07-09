import { Hono } from 'hono';
import { adminAuthMiddleware } from '../middlewares/adminAuth';
import { getQuotaStatus, fetchCustomLimits } from '../utils/rate-limiter';
import { KV_KEYS, getDateKey, getWeekKey, normalizeTier, type CustomQuotaLimits } from '../config/rate-limits';
import { resolveUserTier } from '../utils/subscription';
import { logSubscriptionEvent } from '../utils/subscription-event';
import { ALL_VOICE_MODES, DEFAULT_TEMPLATES, type VoiceMode } from '@xisper/prompts';

type Bindings = {
  AI_KV: KVNamespace;
  DB: D1Database;
  RELEASES_R2?: R2Bucket;
};

const admin = new Hono<{ Bindings: Bindings }>();

// All admin routes require independent admin authentication
admin.use('*', adminAuthMiddleware);

// ============================================
// User Management
// ============================================

/**
 * GET /users — List users with pagination, search, tier filter, activeToday filter
 * Query params: page, pageSize, search, tier, role, activeToday (true = only today-active)
 * "Today active" = has at least one rate_limit_history record since UTC midnight.
 */
admin.get('/users', async (c) => {
  const page = Math.max(1, parseInt(c.req.query('page') || '1'));
  const pageSize = Math.min(100, Math.max(1, parseInt(c.req.query('pageSize') || '20')));
  const search = c.req.query('search') || '';
  const tierFilter = c.req.query('tier') || '';
  const roleFilter = c.req.query('role') || '';
  const activeTodayQuery = c.req.query('activeToday'); // 'true' | 'false' | absent
  const activeTodayFilter = activeTodayQuery === 'true' ? true : activeTodayQuery === 'false' ? false : null;
  const offset = (page - 1) * pageSize;

  const todayStart = new Date();
  todayStart.setUTCHours(0, 0, 0, 0);
  const todayTs = todayStart.getTime();

  let whereClause = '1=1';
  const params: (string | number)[] = [];

  if (search) {
    whereClause += ' AND (u.email LIKE ? OR u.id LIKE ?)';
    params.push(`%${search}%`, `%${search}%`);
  }
  if (tierFilter) {
    whereClause += ' AND u.tier = ?';
    params.push(tierFilter);
  }
  if (roleFilter) {
    whereClause += ' AND u.role = ?';
    params.push(roleFilter);
  }
  if (activeTodayFilter === true) {
    whereClause += ` AND EXISTS (SELECT 1 FROM rate_limit_history r WHERE r.user_id = u.id AND r.timestamp > ? AND r.user_id != 'system')`;
    params.push(todayTs);
  } else if (activeTodayFilter === false) {
    whereClause += ` AND NOT EXISTS (SELECT 1 FROM rate_limit_history r WHERE r.user_id = u.id AND r.timestamp > ? AND r.user_id != 'system')`;
    params.push(todayTs);
  }

  // Count total (from users u)
  const countStmt = c.env.DB.prepare(
    `SELECT COUNT(*) as total FROM users u WHERE ${whereClause}`
  );
  const countResult = await countStmt.bind(...params).first<{ total: number }>();
  const total = countResult?.total || 0;

  // Fetch page with active_today flag (has any rate_limit_history since today UTC)
  const listStmt = c.env.DB.prepare(
    `SELECT u.id, u.email, u.tier, u.role, u.created_at, u.updated_at, u.metadata,
      (SELECT 1 FROM rate_limit_history r WHERE r.user_id = u.id AND r.timestamp > ? AND r.user_id != 'system' LIMIT 1) AS active_today
     FROM users u WHERE ${whereClause} ORDER BY u.created_at DESC LIMIT ? OFFSET ?`
  );
  const listParams = [todayTs, ...params, pageSize, offset];
  const { results } = await listStmt.bind(...listParams).all();

  const data = (results || []).map((row: Record<string, unknown>) => ({
    ...row,
    active_today: Boolean((row.active_today as number) === 1),
  }));

  return c.json({
    success: true,
    data,
    pagination: {
      page,
      pageSize,
      total,
      totalPages: Math.ceil(total / pageSize),
    },
  });
});

/**
 * GET /users/:id — User detail with real-time quota status
 */
admin.get('/users/:id', async (c) => {
  const userId = c.req.param('id');

  const user = await c.env.DB.prepare(
    'SELECT id, email, tier, role, created_at, updated_at, metadata FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  // Get real-time quota status
  const tier = normalizeTier(user.tier);
  const quota = await getQuotaStatus(c.env.AI_KV, userId, tier, null, c.env.DB);

  return c.json({
    success: true,
    data: { ...user, quota },
  });
});

/**
 * PUT /users/:id/tier — Update user tier
 */
admin.put('/users/:id/tier', async (c) => {
  const userId = c.req.param('id');
  const body = await c.req.json<{ tier: string }>();

  const validTiers = ['free', 'pro', 'enterprise', 'unlimited'];
  if (!validTiers.includes(body.tier)) {
    return c.json({ success: false, error: `Invalid tier. Must be one of: ${validTiers.join(', ')}` }, 400);
  }

  const existing = await c.env.DB.prepare(
    'SELECT id, tier FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!existing) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const oldTier = existing.tier;
  await c.env.DB.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind(body.tier, Date.now(), userId).run();

  // Reset quota counters so the user starts fresh with the new tier's limits
  const dateKey = getDateKey();
  const weekKey = getWeekKey();
  await Promise.all([
    c.env.AI_KV.delete(KV_KEYS.LLM(userId, dateKey)),
    c.env.AI_KV.delete(KV_KEYS.ASR_DURATION(userId, weekKey)),
    c.env.AI_KV.delete(KV_KEYS.ASR_CHARS(userId, weekKey)),
  ]);

  console.log(`[Admin] User ${userId} tier changed: ${oldTier} -> ${body.tier} (quota reset) by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, oldTier, newTier: body.tier, quotaReset: true },
  });
});

/**
 * PUT /users/:id/role — Update user role
 */
admin.put('/users/:id/role', async (c) => {
  const userId = c.req.param('id');
  const body = await c.req.json<{ role: string }>();

  const validRoles = ['user', 'admin'];
  if (!validRoles.includes(body.role)) {
    return c.json({ success: false, error: `Invalid role. Must be one of: ${validRoles.join(', ')}` }, 400);
  }

  // Prevent self-demotion
  if (userId === c.get('userId') && body.role !== 'admin') {
    return c.json({ success: false, error: 'Cannot remove your own admin role' }, 400);
  }

  const existing = await c.env.DB.prepare(
    'SELECT id, role FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!existing) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const oldRole = existing.role;
  await c.env.DB.prepare(
    'UPDATE users SET role = ?, updated_at = ? WHERE id = ?'
  ).bind(body.role, Date.now(), userId).run();

  console.log(`[Admin] User ${userId} role changed: ${oldRole} -> ${body.role} by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, oldRole, newRole: body.role },
  });
});

// ============================================
// Quota Management
// ============================================

/**
 * GET /users/:id/quota — Get user quota status
 */
admin.get('/users/:id/quota', async (c) => {
  const userId = c.req.param('id');

  const user = await c.env.DB.prepare(
    'SELECT id, tier FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const tier = normalizeTier(user.tier);
  const customLimits = await fetchCustomLimits(c.env.AI_KV, userId);
  const quota = await getQuotaStatus(c.env.AI_KV, userId, tier, customLimits, c.env.DB);

  return c.json({ success: true, data: { ...quota, customLimits } });
});

/**
 * PUT /users/:id/quota — Override quota values
 * Body: { llm?: number, asrDuration?: number, asrCharacters?: number }
 */
admin.put('/users/:id/quota', async (c) => {
  const userId = c.req.param('id');
  const body = await c.req.json<{
    llm?: number;
    asrDuration?: number;
    asrCharacters?: number;
  }>();

  const user = await c.env.DB.prepare(
    'SELECT id FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const dateKey = getDateKey();
  const weekKey = getWeekKey();
  const updated: string[] = [];

  // Override LLM quota (set usage to the specified value)
  if (body.llm !== undefined) {
    const kvKey = KV_KEYS.LLM(userId, dateKey);
    await c.env.AI_KV.put(kvKey, body.llm.toString(), { expirationTtl: 86400 + 3600 });
    updated.push(`llm=${body.llm}`);
  }

  // Override ASR duration quota
  if (body.asrDuration !== undefined) {
    const kvKey = KV_KEYS.ASR_DURATION(userId, weekKey);
    await c.env.AI_KV.put(kvKey, body.asrDuration.toString(), { expirationTtl: 604800 + 3600 });
    updated.push(`asrDuration=${body.asrDuration}`);
  }

  // Override ASR characters quota
  if (body.asrCharacters !== undefined) {
    const kvKey = KV_KEYS.ASR_CHARS(userId, weekKey);
    await c.env.AI_KV.put(kvKey, body.asrCharacters.toString(), { expirationTtl: 604800 + 3600 });
    updated.push(`asrCharacters=${body.asrCharacters}`);
  }

  console.log(`[Admin] Quota override for ${userId}: ${updated.join(', ')} by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, updated },
  });
});

/**
 * DELETE /users/:id/quota — Reset quota (delete all KV keys)
 */
admin.delete('/users/:id/quota', async (c) => {
  const userId = c.req.param('id');

  const user = await c.env.DB.prepare(
    'SELECT id FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const dateKey = getDateKey();
  const weekKey = getWeekKey();

  await Promise.all([
    c.env.AI_KV.delete(KV_KEYS.LLM(userId, dateKey)),
    c.env.AI_KV.delete(KV_KEYS.ASR_DURATION(userId, weekKey)),
    c.env.AI_KV.delete(KV_KEYS.ASR_CHARS(userId, weekKey)),
  ]);

  console.log(`[Admin] Quota reset for ${userId} by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, message: 'Quota reset successfully' },
  });
});

// ============================================
// Custom Quota Limits (per-user overrides)
// ============================================

/**
 * GET /users/:id/quota-limits — Get per-user custom quota limits
 */
admin.get('/users/:id/quota-limits', async (c) => {
  const userId = c.req.param('id');
  const customLimits = await fetchCustomLimits(c.env.AI_KV, userId);
  return c.json({ success: true, data: customLimits });
});

/**
 * PUT /users/:id/quota-limits — Set per-user custom quota limits
 * Body: { llmCalls?: number, asrDuration?: number, asrCharacters?: number }
 * Overrides tier defaults. Omitted fields fall back to tier defaults.
 * Pass null/0 for a field to clear that specific override.
 */
admin.put('/users/:id/quota-limits', async (c) => {
  const userId = c.req.param('id');
  const body = await c.req.json<{
    llmCalls?: number | null;
    asrDuration?: number | null;
    asrCharacters?: number | null;
  }>();

  const user = await c.env.DB.prepare(
    'SELECT id, tier FROM users WHERE id = ?'
  ).bind(userId).first();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  const existing = await fetchCustomLimits(c.env.AI_KV, userId);
  const merged: CustomQuotaLimits = { ...existing };

  if (body.llmCalls !== undefined) {
    merged.llmCalls = body.llmCalls && body.llmCalls > 0 ? body.llmCalls : undefined;
  }
  if (body.asrDuration !== undefined) {
    merged.asrDuration = body.asrDuration && body.asrDuration > 0 ? body.asrDuration : undefined;
  }
  if (body.asrCharacters !== undefined) {
    merged.asrCharacters = body.asrCharacters && body.asrCharacters > 0 ? body.asrCharacters : undefined;
  }

  const hasOverrides = merged.llmCalls || merged.asrDuration || merged.asrCharacters;

  if (hasOverrides) {
    await c.env.AI_KV.put(KV_KEYS.CUSTOM_LIMITS(userId), JSON.stringify(merged));
  } else {
    await c.env.AI_KV.delete(KV_KEYS.CUSTOM_LIMITS(userId));
  }

  console.log(`[Admin] Custom quota limits for ${userId}: ${JSON.stringify(merged)} by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, customLimits: hasOverrides ? merged : null },
  });
});

/**
 * DELETE /users/:id/quota-limits — Clear all per-user custom quota limits (revert to tier defaults)
 */
admin.delete('/users/:id/quota-limits', async (c) => {
  const userId = c.req.param('id');
  await c.env.AI_KV.delete(KV_KEYS.CUSTOM_LIMITS(userId));

  console.log(`[Admin] Custom quota limits cleared for ${userId} by ${c.get('userId')}`);

  return c.json({
    success: true,
    data: { userId, message: 'Custom quota limits cleared, reverted to tier defaults' },
  });
});

// ============================================
// System Stats
// ============================================

/**
 * GET /stats — System-wide statistics
 */
admin.get('/stats', async (c) => {
  // Total users count
  const totalUsers = await c.env.DB.prepare(
    'SELECT COUNT(*) as count FROM users'
  ).first<{ count: number }>();

  // Tier distribution
  const { results: tierDist } = await c.env.DB.prepare(
    'SELECT tier, COUNT(*) as count FROM users GROUP BY tier'
  ).all();

  // Role distribution
  const { results: roleDist } = await c.env.DB.prepare(
    'SELECT role, COUNT(*) as count FROM users GROUP BY role'
  ).all();

  // Recent signups (last 7 days)
  const weekAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const recentSignups = await c.env.DB.prepare(
    'SELECT COUNT(*) as count FROM users WHERE created_at > ?'
  ).bind(weekAgo).first<{ count: number }>();

  // Today's active users (from rate_limit_history)
  const todayStart = new Date();
  todayStart.setUTCHours(0, 0, 0, 0);
  const todayActive = await c.env.DB.prepare(
    'SELECT COUNT(DISTINCT user_id) as count FROM rate_limit_history WHERE timestamp > ? AND user_id != ?'
  ).bind(todayStart.getTime(), 'system').first<{ count: number }>();

  return c.json({
    success: true,
    data: {
      totalUsers: totalUsers?.count || 0,
      recentSignups: recentSignups?.count || 0,
      todayActive: todayActive?.count || 0,
      tierDistribution: tierDist || [],
      roleDistribution: roleDist || [],
    },
  });
});

/**
 * GET /rate-limit-history — Query rate limit usage history
 * Query params: page, pageSize, userId, type, startTime, endTime
 */
admin.get('/rate-limit-history', async (c) => {
  const page = Math.max(1, parseInt(c.req.query('page') || '1'));
  const pageSize = Math.min(100, Math.max(1, parseInt(c.req.query('pageSize') || '20')));
  const userIdFilter = c.req.query('userId') || '';
  const typeFilter = c.req.query('type') || '';
  const startTime = c.req.query('startTime') || '';
  const endTime = c.req.query('endTime') || '';
  const offset = (page - 1) * pageSize;

  let whereClause = "user_id != 'system'";
  const params: (string | number)[] = [];

  if (userIdFilter) {
    whereClause += ' AND user_id = ?';
    params.push(userIdFilter);
  }
  if (typeFilter) {
    whereClause += ' AND type = ?';
    params.push(typeFilter);
  }
  if (startTime) {
    whereClause += ' AND timestamp >= ?';
    params.push(parseInt(startTime));
  }
  if (endTime) {
    whereClause += ' AND timestamp <= ?';
    params.push(parseInt(endTime));
  }

  const countResult = await c.env.DB.prepare(
    `SELECT COUNT(*) as total FROM rate_limit_history WHERE ${whereClause}`
  ).bind(...params).first<{ total: number }>();
  const total = countResult?.total || 0;

  const { results } = await c.env.DB.prepare(
    `SELECT * FROM rate_limit_history WHERE ${whereClause} ORDER BY timestamp DESC LIMIT ? OFFSET ?`
  ).bind(...params, pageSize, offset).all();

  return c.json({
    success: true,
    data: results,
    pagination: {
      page,
      pageSize,
      total,
      totalPages: Math.ceil(total / pageSize),
    },
  });
});

// ============================================
// Prompt Template Management
// ============================================
// Default templates and the VoiceMode union are imported from @xisper/prompts
// (single source of truth shared with ai-worker, the runtime that actually
// uses these). Do NOT redefine them here — admin UI must show what runtime
// will actually use.

const VALID_VOICE_MODES = ALL_VOICE_MODES;
const PROMPT_KV_PREFIX = 'prompt_template:';

interface StoredTemplate {
  template: string;
  version: string;
  updatedAt: string;
  updatedBy: string;
}

/**
 * GET /prompts — List all prompt templates
 */
admin.get('/prompts', async (c) => {
  const results = await Promise.all(
    VALID_VOICE_MODES.map(async (mode) => {
      const stored = await c.env.AI_KV.get<StoredTemplate>(`${PROMPT_KV_PREFIX}${mode}`, 'json');
      return {
        voiceMode: mode,
        hasCustom: !!stored,
        template: stored?.template ?? null,
        defaultTemplate: DEFAULT_TEMPLATES[mode],
        version: stored?.version ?? null,
        updatedAt: stored?.updatedAt ?? null,
        updatedBy: stored?.updatedBy ?? null,
      };
    }),
  );

  return c.json({ success: true, data: results });
});

/**
 * GET /prompts/:voiceMode — Get template for a specific voice mode
 */
admin.get('/prompts/:voiceMode', async (c) => {
  const voiceMode = c.req.param('voiceMode');
  if (!VALID_VOICE_MODES.includes(voiceMode as any)) {
    return c.json({ success: false, error: `Invalid voiceMode. Must be one of: ${VALID_VOICE_MODES.join(', ')}` }, 400);
  }

  const stored = await c.env.AI_KV.get<StoredTemplate>(`${PROMPT_KV_PREFIX}${voiceMode}`, 'json');

  return c.json({
    success: true,
    data: {
      voiceMode,
      hasCustom: !!stored,
      template: stored?.template ?? null,
      defaultTemplate: DEFAULT_TEMPLATES[voiceMode as VoiceMode],
      version: stored?.version ?? null,
      updatedAt: stored?.updatedAt ?? null,
      updatedBy: stored?.updatedBy ?? null,
    },
  });
});

/**
 * PUT /prompts/:voiceMode — Update prompt template
 */
admin.put('/prompts/:voiceMode', async (c) => {
  const voiceMode = c.req.param('voiceMode');
  if (!VALID_VOICE_MODES.includes(voiceMode as any)) {
    return c.json({ success: false, error: `Invalid voiceMode. Must be one of: ${VALID_VOICE_MODES.join(', ')}` }, 400);
  }

  const body = await c.req.json<{ template: string }>();
  if (!body.template || typeof body.template !== 'string' || !body.template.trim()) {
    return c.json({ success: false, error: 'template is required and must be a non-empty string' }, 400);
  }

  const kvKey = `${PROMPT_KV_PREFIX}${voiceMode}`;
  const existing = await c.env.AI_KV.get<StoredTemplate>(kvKey, 'json');
  const currentVersionNum = existing?.version ? parseInt(existing.version.replace('v', ''), 10) || 0 : 0;
  const nextVersion = `v${currentVersionNum + 1}`;

  const stored: StoredTemplate = {
    template: body.template,
    version: nextVersion,
    updatedAt: new Date().toISOString(),
    updatedBy: c.get('userId') as string,
  };

  await c.env.AI_KV.put(kvKey, JSON.stringify(stored));

  console.log(`[Admin] Prompt template updated: ${voiceMode} -> ${nextVersion} by ${c.get('userId')}`);

  return c.json({ success: true, data: { voiceMode, version: nextVersion } });
});

/**
 * POST /prompts/:voiceMode/reset — Reset to default (delete KV key)
 */
admin.post('/prompts/:voiceMode/reset', async (c) => {
  const voiceMode = c.req.param('voiceMode');
  if (!VALID_VOICE_MODES.includes(voiceMode as any)) {
    return c.json({ success: false, error: `Invalid voiceMode. Must be one of: ${VALID_VOICE_MODES.join(', ')}` }, 400);
  }

  await c.env.AI_KV.delete(`${PROMPT_KV_PREFIX}${voiceMode}`);

  console.log(`[Admin] Prompt template reset to default: ${voiceMode} by ${c.get('userId')}`);

  return c.json({ success: true, data: { voiceMode, message: 'Reset to default' } });
});

// ============================================
// App Release (pre -> latest publish)
// ============================================

/**
 * POST /app-updates/publish?channel=beta|production
 * Copy latest-mac-pre.yml to latest-mac.yml in R2 (promote pre-release to released).
 * Admin only.
 */
admin.post('/app-updates/publish', async (c) => {
  const bucket = c.env.RELEASES_R2;
  if (!bucket) {
    return c.json({ success: false, error: 'RELEASES_R2 not configured' }, 500);
  }

  const channel = c.req.query('channel');
  if (channel !== 'beta' && channel !== 'production') {
    return c.json({ success: false, error: 'Invalid channel; use beta or production' }, 400);
  }

  // Beta Worker can only publish to beta; Production Worker can publish to both
  const env = c.env.ENVIRONMENT || 'development';
  if (env === 'beta' && channel === 'production') {
    return c.json(
      { success: false, error: 'Beta admin cannot publish to production; use production admin' },
      403
    );
  }

  const preKey = `${channel}/latest-mac-pre.yml`;
  const latestKey = `${channel}/latest-mac.yml`;

  const preObj = await bucket.get(preKey);
  if (!preObj) {
    return c.json({ success: false, error: 'Pre-release manifest not found; run a build and upload first' }, 404);
  }

  const body = await preObj.text();
  await bucket.put(latestKey, body);

  console.log(`[Admin] App release published: ${channel} (pre -> latest) by ${c.get('userId')}`);
  return c.json({ success: true, data: { channel, message: 'Published' } });
});

/**
 * POST /app-updates/publish-mac-native?channel=beta|production&criticalUpdate=true|false
 * Copy mac-{channel}/appcast-pre.xml to mac-{channel}/appcast.xml in R2.
 * Optionally inject sparkle:criticalUpdate="true" attribute if criticalUpdate=true.
 * Admin only. For Sparkle-based native macOS app updates.
 */
admin.post('/app-updates/publish-mac-native', async (c) => {
  const bucket = c.env.RELEASES_R2;
  if (!bucket) {
    return c.json({ success: false, error: 'RELEASES_R2 not configured' }, 500);
  }

  const channel = c.req.query('channel');
  if (channel !== 'beta' && channel !== 'production') {
    return c.json({ success: false, error: 'Invalid channel; use beta or production' }, 400);
  }

  const criticalUpdateParam = c.req.query('criticalUpdate');
  const isCritical = criticalUpdateParam === 'true';

  const env = c.env.ENVIRONMENT || 'development';
  if (env === 'beta' && channel === 'production') {
    return c.json(
      { success: false, error: 'Beta admin cannot publish to production; use production admin' },
      403
    );
  }

  const preKey = `mac-${channel}/appcast-pre.xml`;
  const liveKey = `mac-${channel}/appcast.xml`;

  const preObj = await bucket.get(preKey);
  if (!preObj) {
    return c.json({ success: false, error: 'Pre-release appcast not found; run a native build and upload first' }, 404);
  }

  let xmlBody = await preObj.text();

  // Modify appcast XML to set/remove sparkle:criticalUpdate attribute
  if (isCritical) {
    // Add sparkle:criticalUpdate="true" to <enclosure> tag
    // Handle both cases: with and without existing sparkle: attributes
    xmlBody = xmlBody.replace(
      /<enclosure([^>]*?)\/>/g,
      (match) => {
        // If already has sparkle:criticalUpdate, replace its value
        if (match.includes('sparkle:criticalUpdate')) {
          return match.replace(/sparkle:criticalUpdate="[^"]*"/, 'sparkle:criticalUpdate="true"');
        }
        // Otherwise, add it before the closing />
        return match.replace(/\s*\/>$/, ' sparkle:criticalUpdate="true"/>');
      }
    );
  } else {
    // Remove sparkle:criticalUpdate attribute entirely
    xmlBody = xmlBody.replace(
      /\s+sparkle:criticalUpdate="[^"]*"/g,
      ''
    );
  }

  await bucket.put(liveKey, xmlBody);

  console.log(`[Admin] Mac native release published: ${channel} (appcast-pre -> appcast, critical=${isCritical}) by ${c.get('userId')}`);
  return c.json({
    success: true,
    data: {
      channel,
      isCritical,
      message: `Mac native update published${isCritical ? ' (CRITICAL - forced update)' : ''}`,
    },
  });
});

// ============================================
// Identity Management
// ============================================

const IDENTITIES_INDEX_KEY = 'identities_index';
const IDENTITY_PREFIX = 'identity:';

interface CorrectionRule {
  correct: string;
  misheard?: string[];
  note?: string;
}

interface HotwordEntry {
  text: string;
  weight: number;
  lang: string;
}

interface IdentityIndex {
  id: string;
  label: string;
  description?: string;
  enabled: boolean;
  updatedAt: number;
  correctionCount: number;
  vocabularyId?: string;
}

interface Identity extends IdentityIndex {
  corrections: CorrectionRule[];
  hotwords?: HotwordEntry[];
}

async function loadIdentityIndex(kv: KVNamespace): Promise<IdentityIndex[]> {
  const raw = await kv.get<IdentityIndex[]>(IDENTITIES_INDEX_KEY, 'json');
  return raw ?? [];
}

async function saveIdentityIndex(kv: KVNamespace, index: IdentityIndex[]): Promise<void> {
  await kv.put(IDENTITIES_INDEX_KEY, JSON.stringify(index));
}

admin.get('/identities', async (c) => {
  const index = await loadIdentityIndex(c.env.AI_KV);
  return c.json({ success: true, data: index });
});

admin.get('/identities/:id', async (c) => {
  const id = c.req.param('id');
  const identity = await c.env.AI_KV.get<Identity>(`${IDENTITY_PREFIX}${id}`, 'json');
  if (!identity) {
    return c.json({ success: false, error: 'Identity not found' }, 404);
  }
  return c.json({ success: true, data: identity });
});

admin.post('/identities', async (c) => {
  const body = await c.req.json<{
    id: string;
    label: string;
    description?: string;
    corrections: CorrectionRule[];
    enabled?: boolean;
    vocabularyId?: string;
    hotwords?: HotwordEntry[];
  }>();

  if (!body.id || !body.label || !Array.isArray(body.corrections)) {
    return c.json({ success: false, error: 'id, label, and corrections are required' }, 400);
  }

  const existing = await c.env.AI_KV.get(`${IDENTITY_PREFIX}${body.id}`);
  if (existing) {
    return c.json({ success: false, error: 'Identity with this id already exists' }, 409);
  }

  const now = Date.now();
  const identity: Identity = {
    id: body.id,
    label: body.label,
    description: body.description,
    corrections: body.corrections,
    enabled: body.enabled ?? true,
    updatedAt: now,
    correctionCount: body.corrections.length,
    vocabularyId: body.vocabularyId ?? '',
    hotwords: body.hotwords ?? [],
  };

  await c.env.AI_KV.put(`${IDENTITY_PREFIX}${body.id}`, JSON.stringify(identity));

  const index = await loadIdentityIndex(c.env.AI_KV);
  index.push({
    id: identity.id,
    label: identity.label,
    description: identity.description,
    enabled: identity.enabled,
    updatedAt: identity.updatedAt,
    correctionCount: identity.correctionCount,
    vocabularyId: identity.vocabularyId,
  });
  await saveIdentityIndex(c.env.AI_KV, index);

  console.log(`[Admin] Identity created: ${body.id} (${body.corrections.length} corrections) by ${c.get('userId')}`);
  return c.json({ success: true, data: identity }, 201);
});

admin.put('/identities/:id', async (c) => {
  const id = c.req.param('id');
  const body = await c.req.json<{
    label?: string;
    description?: string;
    corrections?: CorrectionRule[];
    enabled?: boolean;
    vocabularyId?: string;
    hotwords?: HotwordEntry[];
  }>();

  const existing = await c.env.AI_KV.get<Identity>(`${IDENTITY_PREFIX}${id}`, 'json');
  if (!existing) {
    return c.json({ success: false, error: 'Identity not found' }, 404);
  }

  const now = Date.now();
  const updated: Identity = {
    ...existing,
    label: body.label ?? existing.label,
    description: body.description !== undefined ? body.description : existing.description,
    corrections: body.corrections ?? existing.corrections,
    enabled: body.enabled ?? existing.enabled,
    updatedAt: now,
    correctionCount: (body.corrections ?? existing.corrections).length,
    vocabularyId: body.vocabularyId ?? existing.vocabularyId,
    hotwords: body.hotwords ?? existing.hotwords,
  };

  await c.env.AI_KV.put(`${IDENTITY_PREFIX}${id}`, JSON.stringify(updated));

  const index = await loadIdentityIndex(c.env.AI_KV);
  const idx = index.findIndex((p) => p.id === id);
  const indexEntry: IdentityIndex = {
    id: updated.id,
    label: updated.label,
    description: updated.description,
    enabled: updated.enabled,
    updatedAt: updated.updatedAt,
    correctionCount: updated.correctionCount,
    vocabularyId: updated.vocabularyId,
  };
  if (idx >= 0) {
    index[idx] = indexEntry;
  } else {
    index.push(indexEntry);
  }
  await saveIdentityIndex(c.env.AI_KV, index);

  console.log(`[Admin] Identity updated: ${id} by ${c.get('userId')}`);
  return c.json({ success: true, data: updated });
});

admin.delete('/identities/:id', async (c) => {
  const id = c.req.param('id');
  const existing = await c.env.AI_KV.get(`${IDENTITY_PREFIX}${id}`);
  if (!existing) {
    return c.json({ success: false, error: 'Identity not found' }, 404);
  }

  await c.env.AI_KV.delete(`${IDENTITY_PREFIX}${id}`);

  const index = await loadIdentityIndex(c.env.AI_KV);
  const filtered = index.filter((p) => p.id !== id);
  await saveIdentityIndex(c.env.AI_KV, filtered);

  console.log(`[Admin] Identity deleted: ${id} by ${c.get('userId')}`);
  return c.json({ success: true, data: { id, message: 'Deleted' } });
});

// ============================================
// Subscription Management
// ============================================

/**
 * POST /subscription/grant — Grant Pro to a user
 * Body: { user_id, source?: 'admin'|'promo', days: number, reason?: string }
 */
admin.post('/subscription/grant', async (c) => {
  const body = await c.req.json().catch(() => null);
  if (!body?.user_id || !body?.days) {
    return c.json({ success: false, error: 'user_id and days are required' }, 400);
  }

  const userId = body.user_id as string;
  const days = Math.max(1, Math.min(365, parseInt(body.days) || 30));
  const source = body.source === 'promo' ? 'promo' : 'admin';
  const reason = (body.reason as string) || '';

  // Verify user exists
  const user = await c.env.DB.prepare(
    'SELECT id, tier FROM users WHERE id = ?'
  ).bind(userId).first<{ id: string; tier: string }>();

  if (!user) {
    return c.json({ success: false, error: 'User not found' }, 404);
  }

  // One user = one active subscription at a time
  const existing = await c.env.DB.prepare(
    "SELECT id, source FROM subscriptions WHERE user_id = ? AND status IN ('active', 'past_due') LIMIT 1"
  ).bind(userId).first<{ id: string; source: string }>();

  if (existing) {
    return c.json({
      success: false,
      error: `User already has an active subscription (source: ${existing.source})`,
    }, 400);
  }

  const now = Date.now();
  const periodEnd = now + days * 24 * 60 * 60 * 1000;
  const id = crypto.randomUUID();

  await c.env.DB.prepare(
    `INSERT INTO subscriptions
       (id, user_id, source, plan, status, current_period_start, current_period_end, created_at, updated_at, metadata)
     VALUES (?, ?, ?, 'pro_monthly', 'active', ?, ?, ?, ?, ?)`
  ).bind(id, userId, source, now, periodEnd, now, now, JSON.stringify({ reason, granted_by: c.get('userId') })).run();

  // Update tier
  await c.env.DB.prepare(
    'UPDATE users SET tier = ?, updated_at = ? WHERE id = ?'
  ).bind('pro', now, userId).run();

  try {
    await logSubscriptionEvent(c.env.DB, {
      subscriptionId: id,
      userId,
      trigger: 'admin',
      eventType: 'created',
      beforeState: { tier: user.tier },
      afterState: { status: 'active', tier: 'pro' },
      detail: { source, days, reason, granted_by: c.get('userId') },
    });
  } catch (e) {
    console.error('[Admin] Failed to log grant event:', e);
  }

  console.info(`[Admin] Granted ${source} Pro to ${userId} for ${days} days by ${c.get('userId')}`);

  return c.json({
    success: true,
    subscription: { id, source, status: 'active', periodEnd },
  });
});

/**
 * POST /subscription/revoke — Revoke non-creem subscription
 * Body: { user_id, reason?: string }
 */
admin.post('/subscription/revoke', async (c) => {
  const body = await c.req.json().catch(() => null);
  if (!body?.user_id) {
    return c.json({ success: false, error: 'user_id is required' }, 400);
  }

  const userId = body.user_id as string;
  const reason = (body.reason as string) || '';
  const now = Date.now();

  // Find active non-creem subscriptions
  const subs = await c.env.DB.prepare(
    "SELECT id, source, status FROM subscriptions WHERE user_id = ? AND source != 'creem' AND status = 'active'"
  ).bind(userId).all<{ id: string; source: string; status: string }>();

  if (!subs.results?.length) {
    return c.json({ success: false, error: 'No active admin/promo subscription found' }, 404);
  }

  // Expire all non-creem active subscriptions
  for (const sub of subs.results) {
    await c.env.DB.prepare(
      "UPDATE subscriptions SET status = 'expired', updated_at = ? WHERE id = ?"
    ).bind(now, sub.id).run();

    try {
      await logSubscriptionEvent(c.env.DB, {
        subscriptionId: sub.id,
        userId,
        trigger: 'admin',
        eventType: 'revoked',
        beforeState: { status: 'active' },
        afterState: { status: 'expired' },
        detail: { reason, revoked_by: c.get('userId') },
      });
    } catch (e) {
      console.error('[Admin] Failed to log revoke event:', e);
    }
  }

  // Re-resolve tier (might still be pro if creem subscription exists)
  const newTier = await resolveUserTier(c.env.DB, userId);

  console.info(`[Admin] Revoked ${subs.results.length} subscription(s) for ${userId}, new tier: ${newTier}`);

  return c.json({ success: true, revokedCount: subs.results.length, currentTier: newTier });
});

/**
 * GET /subscription/events/:userId — Query subscription events for a user
 */
admin.get('/subscription/events/:userId', async (c) => {
  const userId = c.req.param('userId');
  const limit = Math.min(100, parseInt(c.req.query('limit') || '50'));
  const offset = parseInt(c.req.query('offset') || '0');

  const result = await c.env.DB.prepare(
    'SELECT * FROM subscription_events WHERE user_id = ? ORDER BY created_at DESC LIMIT ? OFFSET ?'
  ).bind(userId, limit, offset).all();

  const total = await c.env.DB.prepare(
    'SELECT COUNT(*) as count FROM subscription_events WHERE user_id = ?'
  ).bind(userId).first<{ count: number }>();

  return c.json({
    success: true,
    events: result.results?.map((e: any) => ({
      ...e,
      before_state: e.before_state ? JSON.parse(e.before_state) : null,
      after_state: e.after_state ? JSON.parse(e.after_state) : null,
      detail: e.detail ? JSON.parse(e.detail) : null,
    })) || [],
    total: total?.count || 0,
  });
});

export default admin;
export { IDENTITIES_INDEX_KEY, IDENTITY_PREFIX };
export type { Identity, IdentityIndex, CorrectionRule, HotwordEntry };

// Backward compatibility aliases
export const CORRECTION_PACKS_INDEX_KEY = IDENTITIES_INDEX_KEY;
export const CORRECTION_PACK_PREFIX = IDENTITY_PREFIX;
export type CorrectionPack = Identity;
export type CorrectionPackIndex = IdentityIndex;
