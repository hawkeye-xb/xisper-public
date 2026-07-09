import { Hono } from 'hono';
import { authMiddleware } from '../middlewares/auth';

type Bindings = {
  DB: D1Database;
};

const hotwords = new Hono<{ Bindings: Bindings }>();

// All hotword routes require auth
hotwords.use('*', authMiddleware);

// ── Constants ──────────────────────────────────────────────
const MAX_HOTWORD_LENGTH = 64;
const MAX_BATCH_SIZE = 500;
const MAX_HOTWORDS_PER_USER = 500;

// ── Helpers ────────────────────────────────────────────────

/** Normalize text: trim + collapse whitespace. Must match client-side HotwordItem.normalise(). */
function normalize(text: string): string {
  return text.trim().replace(/\s+/g, ' ');
}

/** Validate a single hotword text. Returns error string or null. */
function validateText(text: string): string | null {
  if (typeof text !== 'string') return 'Text must be a string';
  const n = normalize(text);
  if (n.length === 0) return 'Text cannot be empty';
  if (n.length > MAX_HOTWORD_LENGTH) return `Text too long (max ${MAX_HOTWORD_LENGTH})`;
  if (/[\x00-\x1F\x7F]/.test(n)) return 'Control characters not allowed';
  return null;
}

/** Validate UUID format. */
function validateId(id: string): boolean {
  return typeof id === 'string' && /^[a-zA-Z0-9\-]{36}$/.test(id);
}

// ── GET / — list all hotwords ──────────────────────────────
hotwords.get('/', async (c) => {
  const userId = c.get('userId') as string;

  const { results } = await c.env.DB.prepare(
    'SELECT id, text, created_at, updated_at FROM hotwords WHERE user_id = ? ORDER BY updated_at DESC'
  ).bind(userId).all<{ id: string; text: string; created_at: number; updated_at: number }>();

  const items = (results || []).map(r => ({
    id: r.id,
    text: r.text,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  }));

  return c.json({ items, total: items.length });
});

// ── POST / — create hotwords (single or batch) ────────────
hotwords.post('/', async (c) => {
  const userId = c.get('userId') as string;
  const body = await c.req.json<{ items: Array<{ id: string; text: string }> }>();

  if (!Array.isArray(body.items) || body.items.length === 0) {
    return c.json({ error: 'items must be a non-empty array' }, 400);
  }
  if (body.items.length > MAX_BATCH_SIZE) {
    return c.json({ error: `Batch size exceeds ${MAX_BATCH_SIZE}` }, 400);
  }

  // Check current count
  const countRow = await c.env.DB.prepare(
    'SELECT COUNT(*) as total FROM hotwords WHERE user_id = ?'
  ).bind(userId).first<{ total: number }>();
  const currentCount = countRow?.total || 0;

  const now = Date.now();
  let created = 0;
  const duplicates: string[] = [];

  for (const item of body.items) {
    // Validate
    if (!validateId(item.id)) {
      return c.json({ error: `Invalid ID format: ${item.id}` }, 400);
    }
    const textErr = validateText(item.text);
    if (textErr) {
      return c.json({ error: `${textErr}: "${item.text}"` }, 400);
    }

    if (currentCount + created >= MAX_HOTWORDS_PER_USER) {
      return c.json({ error: `Hotword limit reached (${MAX_HOTWORDS_PER_USER})` }, 429);
    }

    const normalizedText = normalize(item.text);

    try {
      await c.env.DB.prepare(
        'INSERT INTO hotwords (id, user_id, text, normalized_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)'
      ).bind(item.id, userId, normalizedText, normalizedText, now, now).run();
      created++;
    } catch (e: any) {
      // UNIQUE constraint violation → duplicate
      if (e.message?.includes('UNIQUE') || e.message?.includes('unique')) {
        duplicates.push(normalizedText);
      } else {
        throw e;
      }
    }
  }

  return c.json({ created, duplicates, total: currentCount + created });
});

// ── DELETE /all — delete all hotwords for the user ─────────
hotwords.delete('/all', async (c) => {
  const userId = c.get('userId') as string;

  const countRow = await c.env.DB.prepare(
    'SELECT COUNT(*) as total FROM hotwords WHERE user_id = ?'
  ).bind(userId).first<{ total: number }>();
  const total = countRow?.total || 0;

  await c.env.DB.prepare(
    'DELETE FROM hotwords WHERE user_id = ?'
  ).bind(userId).run();

  return c.json({ deleted: total });
});

// ── DELETE /:id — delete a hotword ─────────────────────────
hotwords.delete('/:id', async (c) => {
  const userId = c.get('userId') as string;
  const id = c.req.param('id');

  await c.env.DB.prepare(
    'DELETE FROM hotwords WHERE id = ? AND user_id = ?'
  ).bind(id, userId).run();

  return c.json({ success: true });
});

// ── PUT /:id — update a hotword ────────────────────────────
hotwords.put('/:id', async (c) => {
  const userId = c.get('userId') as string;
  const id = c.req.param('id');
  const body = await c.req.json<{ text: string }>();

  const textErr = validateText(body.text);
  if (textErr) {
    return c.json({ error: textErr }, 400);
  }

  const normalizedText = normalize(body.text);
  const now = Date.now();

  try {
    const result = await c.env.DB.prepare(
      'UPDATE hotwords SET text = ?, normalized_text = ?, updated_at = ? WHERE id = ? AND user_id = ?'
    ).bind(normalizedText, normalizedText, now, id, userId).run();

    if (!result.meta.changes) {
      return c.json({ error: 'Hotword not found' }, 404);
    }

    return c.json({ id, text: normalizedText, updatedAt: now });
  } catch (e: any) {
    if (e.message?.includes('UNIQUE') || e.message?.includes('unique')) {
      return c.json({ error: 'Duplicate hotword' }, 409);
    }
    throw e;
  }
});

// ── POST /import — batch import from text array ────────────
hotwords.post('/import', async (c) => {
  const userId = c.get('userId') as string;
  const body = await c.req.json<{ items: string[] }>();

  if (!Array.isArray(body.items) || body.items.length === 0) {
    return c.json({ error: 'items must be a non-empty array' }, 400);
  }
  if (body.items.length > MAX_BATCH_SIZE) {
    return c.json({ error: `Batch size exceeds ${MAX_BATCH_SIZE}` }, 400);
  }

  const countRow = await c.env.DB.prepare(
    'SELECT COUNT(*) as total FROM hotwords WHERE user_id = ?'
  ).bind(userId).first<{ total: number }>();
  let currentCount = countRow?.total || 0;

  const now = Date.now();
  let imported = 0;
  let skipped = 0;

  for (const text of body.items) {
    if (typeof text !== 'string') { skipped++; continue; }
    const normalizedText = normalize(text);
    if (normalizedText.length === 0 || normalizedText.length > MAX_HOTWORD_LENGTH) { skipped++; continue; }
    if (/[\x00-\x1F\x7F]/.test(normalizedText)) { skipped++; continue; }
    if (currentCount >= MAX_HOTWORDS_PER_USER) { skipped++; continue; }

    const id = crypto.randomUUID();
    try {
      await c.env.DB.prepare(
        'INSERT INTO hotwords (id, user_id, text, normalized_text, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)'
      ).bind(id, userId, normalizedText, normalizedText, now, now).run();
      imported++;
      currentCount++;
    } catch {
      skipped++; // Duplicate
    }
  }

  return c.json({ imported, skipped, total: currentCount });
});

// ── GET /export — export all hotwords as text array ────────
hotwords.get('/export', async (c) => {
  const userId = c.get('userId') as string;

  const { results } = await c.env.DB.prepare(
    'SELECT text FROM hotwords WHERE user_id = ? ORDER BY updated_at DESC'
  ).bind(userId).all<{ text: string }>();

  const items = (results || []).map(r => r.text);
  return c.json({ items, exportedAt: Date.now() });
});

export default hotwords;
