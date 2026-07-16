import { Hono } from 'hono'
import { cors } from 'hono/cors'
import { logger } from 'hono/logger'
import postprocessRouter from './routes/postprocess'
import chatRouter from './routes/chat'
import meteringRouter from './routes/metering'
import { getConfiguredProviders } from './providers/ai-gateway'
import { DEPLOY_INFO } from './generated/deploy-info'

export { AIAgent } from './agent/ai-agent'
// Re-export for wrangler DO binding

export type Env = {
  AI: Ai
  AI_KV: KVNamespace
  DB: D1Database
  AI_AGENT: DurableObjectNamespace
  // CN direct providers (fastest for CN users, bypass AI Gateway)
  ZHIPU_API_KEY?: string
  ALIBABA_API_KEY?: string
  // Global direct providers (OpenRouter)
  OPENROUTER_API_KEY?: string
  // AI Gateway providers (Groq > Gemini > DeepSeek)
  GROQ_API_KEY?: string
  GEMINI_API_KEY?: string
  DEEPSEEK_API_KEY?: string
  ENVIRONMENT: string
  ALLOWED_ORIGINS?: string
}

const app = new Hono<{ Bindings: Env }>()

app.use('*', logger())
app.use('*', async (c, next) => {
  const allowedOrigins = new Set(
    (c.env.ALLOWED_ORIGINS || '').split(',').map(value => value.trim()).filter(Boolean),
  )
  const isDevelopment = !c.env.ENVIRONMENT || c.env.ENVIRONMENT === 'development'
  return cors({
    origin: origin => {
      if (allowedOrigins.has(origin)) return origin
      if (isDevelopment && /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) return origin
      return ''
    },
  })(c, next)
})

app.get('/health', (c) => {
  return c.json({
    status: 'ok',
    service: 'xisper-ai-worker',
    environment: c.env.ENVIRONMENT || 'unknown',
    deploy: DEPLOY_INFO,
    gateway: {
      id: 'xisper-ai',
      providers: getConfiguredProviders(c.env),
    },
  })
})

app.route('/', postprocessRouter)
app.route('/', chatRouter)
app.route('/', meteringRouter)

export default app
