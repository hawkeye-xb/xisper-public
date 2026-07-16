import { Hono } from 'hono'
import { loadTemplate } from '../prompts/template-store'
import { buildPostprocessPrompt } from '../prompts/builder'
import { gatewayComplete } from '../providers/ai-gateway'
import type { VoiceMode } from '../prompts/templates'
import type { Env } from '../index'
import { applyITN } from '../utils/itn'

export interface PostprocessRequest {
  text: string

  config: {
    mode: 'clean' | 'rewrite'
    voiceMode: VoiceMode
    features: {
      correction: boolean
      formatting: boolean
      hotwords: boolean
      rewrite: boolean
    }
  }

  context?: {
    app?: { name: string; bundleId: string }
    windowTitle?: string
    url?: string
    domain?: string
    selectedText?: string
    visibleText?: string
    windowText?: string
  }

  hotwords?: string[]
  corrections?: Array<{
    correct: string
    misheard?: string[]
    note?: string
  }>

  llm?: {
    temperature?: number
    maxTokens?: number
    model?: string  // Allow manual model override
  }

  translationInstruction?: string

  stream?: boolean

  // Speech language hint for model selection
  speechLanguage?: string  // e.g., "zh-CN", "en-US", "ja-JP"

  // Identity context: label + description of the active identity (e.g. "程序员 — 软件开发、编程")
  identityContext?: string

  // Identity ID — when set, server reads identity from KV and overrides
  // corrections / hotwords / identityContext (KV is the source of truth).
  identityId?: string
}

interface KVIdentity {
  id: string
  label: string
  description?: string
  enabled: boolean
  corrections?: Array<{ correct: string; misheard?: string[]; note?: string }>
  hotwords?: Array<{ text: string; weight?: number; lang?: string } | string>
}

/**
 * Resolve identity from KV and overwrite identity-derived fields on the request.
 * KV is the single source of truth — any client-sent corrections/hotwords/identityContext
 * are discarded when identityId is provided and the identity exists in KV.
 */
async function applyIdentityFromKV(req: PostprocessRequest, kv: KVNamespace): Promise<void> {
  if (!req.identityId) return
  let identity: KVIdentity | null = null
  try {
    identity = await kv.get<KVIdentity>(`identity:${req.identityId}`, 'json')
  } catch (e) {
    console.warn(`[Postprocess] KV lookup for identity:${req.identityId} failed:`, (e as Error).message)
    return
  }
  if (!identity) {
    console.warn(`[Postprocess] identity:${req.identityId} not found in KV`)
    return
  }

  req.corrections = Array.isArray(identity.corrections) ? identity.corrections : []

  if (Array.isArray(identity.hotwords)) {
    req.hotwords = identity.hotwords
      .map((h) => (typeof h === 'string' ? h : h?.text))
      .filter((s): s is string => typeof s === 'string' && s.length > 0)
  } else {
    req.hotwords = []
  }

  const label = identity.label?.trim()
  const desc = identity.description?.trim()
  req.identityContext = label ? (desc ? `${label} — ${desc}` : label) : undefined

  console.log(`[Postprocess] Identity override from KV: id=${identity.id}, corrections=${req.corrections.length}, hotwords=${req.hotwords.length}`)
}

const postprocessRouter = new Hono<{ Bindings: Env }>()

/**
 * Infer preferred model from speech language or text content
 * @param speechLanguage - Language code (e.g., "zh-CN", "en-US")
 * @param text - Transcript text for heuristic detection
 * @returns Model preference: "qwen3-32b" for Chinese, "llama-3.3-70b" for others
 */
function inferModelFromLanguage(speechLanguage: string | undefined, text: string): string | undefined {
  // Explicit language code
  if (speechLanguage) {
    const lang = speechLanguage.toLowerCase()
    if (lang.startsWith('zh') || lang.startsWith('cn')) {
      return 'qwen3-32b'  // Chinese: prefer Qwen3 (better Chinese, faster, cheaper)
    }
    if (lang.startsWith('ja') || lang.startsWith('ko')) {
      return 'qwen3-32b'  // Japanese/Korean: Qwen3 also good for CJK
    }
    return 'llama-3.3-70b'  // English/others: prefer Llama 3.3
  }

  // Heuristic: detect Chinese characters
  const chineseCharCount = (text.match(/[\u4e00-\u9fa5]/g) || []).length
  if (chineseCharCount > text.length * 0.3) {  // >30% Chinese chars
    return 'qwen3-32b'
  }

  return undefined  // Let gateway use default order
}

postprocessRouter.post('/v1/postprocess', async (c) => {
  const t0 = Date.now()
  const req = await c.req.json<PostprocessRequest>()
  const country = c.req.header('X-Client-Country')

  if (!req.text || !req.config) {
    return c.json({ success: false, error: 'Missing required fields: text, config' }, 400)
  }

  // Apply rule-based ITN before building the LLM prompt.
  req.text = applyITN(req.text)

  // Identity is the single source of truth: when identityId is set, KV overrides
  // corrections / hotwords / identityContext, ignoring whatever client sent.
  await applyIdentityFromKV(req, c.env.AI_KV)

  const voiceMode = req.config.voiceMode || 'dictation'
  const hasSelection = !!(req.context?.selectedText && req.context.selectedText.trim().length > 0)

  const tTemplate = Date.now()
  const loaded = await loadTemplate(c.env.AI_KV, voiceMode)
  const templateMs = Date.now() - tTemplate

  const { messages } = buildPostprocessPrompt(req, loaded.template)

  console.log(`[Postprocess] mode=${hasSelection ? 'SELECTED_TEXT' : 'DICTATION'}, voiceMode=${voiceMode}, template=${loaded.source}:${loaded.version}, textLen=${req.text.length}, selectedTextLen=${req.context?.selectedText?.length ?? 0}, country=${country || 'unknown'}`)

  const tGateway = Date.now()
  const response = await gatewayComplete(c.env.AI, c.env, {
    messages,
    temperature: req.llm?.temperature ?? 0.3,
    maxTokens: req.llm?.maxTokens,
    stream: req.stream ?? true,
    preferredModel: req.llm?.model || inferModelFromLanguage(req.speechLanguage, req.text),
  }, country)
  const gatewayMs = Date.now() - tGateway

  const step = response.headers.get('cf-aig-step')
  const totalMs = Date.now() - t0

  console.log(`[Postprocess:Timing] total=${totalMs}ms, template=${templateMs}ms, gateway=${gatewayMs}ms, step=${step || '?'}, country=${country || 'unknown'}`)

  return new Response(response.body, {
    status: response.status,
    headers: {
      'Content-Type': response.headers.get('Content-Type') || 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'X-Template-Version': loaded.version,
      'X-Template-Source': loaded.source,
      ...(step ? { 'X-AI-Provider-Step': step } : {}),
    },
  })
})

export default postprocessRouter
