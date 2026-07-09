import { Hono } from 'hono'
import { gatewayComplete } from '../providers/ai-gateway'
import type { Env } from '../index'

interface ChatRequest {
  messages: Array<{ role: string; content: string }>
  model?: string
  temperature?: number
  maxTokens?: number
  stream?: boolean
}

const chatRouter = new Hono<{ Bindings: Env }>()

chatRouter.post('/v1/chat', async (c) => {
  const t0 = Date.now()
  const req = await c.req.json<ChatRequest>()
  const country = c.req.header('X-Client-Country')

  if (!req.messages || req.messages.length === 0) {
    return c.json({ success: false, error: 'Missing required field: messages' }, 400)
  }

  const response = await gatewayComplete(c.env.AI, c.env, {
    messages: req.messages,
    temperature: req.temperature,
    maxTokens: req.maxTokens,
    stream: req.stream ?? true,
  }, country)

  const step = response.headers.get('cf-aig-step')
  const totalMs = Date.now() - t0

  console.log(`[Chat:Timing] total=${totalMs}ms, step=${step || '?'}, country=${country || 'unknown'}`)

  return new Response(response.body, {
    status: response.status,
    headers: {
      'Content-Type': response.headers.get('Content-Type') || 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      ...(step ? { 'X-AI-Provider-Step': step } : {}),
    },
  })
})

export default chatRouter
