import { Hono } from 'hono'
import type { Env } from '../index'

type MeteringAction =
  | 'consume_duration'
  | 'consume_characters'
  | 'refund_duration'
  | 'refund_characters'
  | 'consume_llm'
  | 'audit'

interface MeteringPayload {
  action: MeteringAction
  userId: string
  amount: number
  tier: string
  metadata?: Record<string, any>
}

function getDateKey(): string {
  return new Date().toISOString().split('T')[0]
}

function getWeekKey(): string {
  const now = new Date()
  const year = now.getUTCFullYear()
  const startOfYear = new Date(Date.UTC(year, 0, 1))
  const days = Math.floor((now.getTime() - startOfYear.getTime()) / 86400000)
  const week = Math.ceil((days + startOfYear.getUTCDay() + 1) / 7)
  return `${year}-W${String(week).padStart(2, '0')}`
}

function getLLMQuotaTTL(): number {
  const now = new Date()
  const resetTime = new Date(now)
  resetTime.setUTCHours(19, 0, 0, 0)
  if (now >= resetTime) resetTime.setUTCDate(resetTime.getUTCDate() + 1)
  return Math.ceil((resetTime.getTime() - now.getTime()) / 1000) + 3600
}

const meteringRouter = new Hono<{ Bindings: Env & { DB: D1Database } }>()

meteringRouter.post('/v1/metering', async (c) => {
  const body = await c.req.json<MeteringPayload>()
  const { action, userId, amount, tier, metadata } = body

  if (!userId || !action || amount == null) {
    return c.json({ error: 'Missing required fields' }, 400)
  }

  const db = c.env.DB
  if (!db) {
    console.warn('[Metering] D1 binding not available')
    return c.json({ error: 'D1 not configured' }, 500)
  }

  const now = Date.now()

  try {
    switch (action) {
      case 'consume_duration': {
        const weekKey = getWeekKey()
        const result = await db.prepare(
          'SELECT duration_used FROM user_asr_quota WHERE user_id = ? AND week_key = ?'
        ).bind(userId, weekKey).first<{ duration_used: number }>()

        if (result) {
          await db.prepare(
            'UPDATE user_asr_quota SET duration_used = duration_used + ?, tier = ?, updated_at = ? WHERE user_id = ? AND week_key = ?'
          ).bind(Math.floor(amount), tier, now, userId, weekKey).run()
        } else {
          await db.prepare(
            'INSERT INTO user_asr_quota (id, user_id, week_key, duration_used, characters_used, tier, updated_at, created_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?)'
          ).bind(`asr_${userId}_${weekKey}`, userId, weekKey, Math.floor(amount), tier, now, now).run()
        }
        break
      }

      case 'consume_characters': {
        const weekKey = getWeekKey()
        const result = await db.prepare(
          'SELECT characters_used FROM user_asr_quota WHERE user_id = ? AND week_key = ?'
        ).bind(userId, weekKey).first<{ characters_used: number }>()

        if (result) {
          await db.prepare(
            'UPDATE user_asr_quota SET characters_used = characters_used + ?, tier = ?, updated_at = ? WHERE user_id = ? AND week_key = ?'
          ).bind(Math.floor(amount), tier, now, userId, weekKey).run()
        } else {
          await db.prepare(
            'INSERT INTO user_asr_quota (id, user_id, week_key, duration_used, characters_used, tier, updated_at, created_at) VALUES (?, ?, ?, 0, ?, ?, ?, ?)'
          ).bind(`asr_${userId}_${weekKey}`, userId, weekKey, Math.floor(amount), tier, now, now).run()
        }
        break
      }

      case 'refund_duration': {
        const weekKey = getWeekKey()
        await db.prepare(
          'UPDATE user_asr_quota SET duration_used = MAX(0, duration_used - ?), tier = ?, updated_at = ? WHERE user_id = ? AND week_key = ?'
        ).bind(Math.floor(amount), tier, now, userId, weekKey).run()
        break
      }

      case 'refund_characters': {
        const weekKey = getWeekKey()
        await db.prepare(
          'UPDATE user_asr_quota SET characters_used = MAX(0, characters_used - ?), tier = ?, updated_at = ? WHERE user_id = ? AND week_key = ?'
        ).bind(Math.floor(amount), tier, now, userId, weekKey).run()
        break
      }

      case 'consume_llm': {
        const dateKey = getDateKey()
        const kvKey = `rate:llm:${userId}:${dateKey}`
        const currentStr = await c.env.AI_KV.get(kvKey)
        const newUsage = (currentStr ? parseInt(currentStr, 10) : 0) + 1
        await c.env.AI_KV.put(kvKey, newUsage.toString(), { expirationTtl: getLLMQuotaTTL() })

        const hid = `history_${now}_${Math.random().toString(36).substring(2, 10)}`
        await db.prepare(
          'INSERT INTO rate_limit_history (id, user_id, type, metric, amount, tier, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(hid, userId, 'llm', 'calls', 1, tier, JSON.stringify(metadata || {}), now).run()
        break
      }

      case 'audit': {
        const hid = `history_${now}_${Math.random().toString(36).substring(2, 10)}`
        const auditType = metadata?.type || 'asr'
        const metric = metadata?.metric || 'unknown'
        await db.prepare(
          'INSERT INTO rate_limit_history (id, user_id, type, metric, amount, tier, metadata, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        ).bind(hid, userId, auditType, metric, Math.floor(amount), tier, JSON.stringify(metadata || {}), now).run()
        break
      }
    }

    return c.json({ ok: true })
  } catch (e) {
    console.error(`[Metering] ${action} failed:`, (e as Error).message)
    return c.json({ error: (e as Error).message }, 500)
  }
})

export default meteringRouter
