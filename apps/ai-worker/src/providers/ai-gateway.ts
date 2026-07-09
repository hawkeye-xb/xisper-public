const GATEWAY_ID = 'xisper-ai'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface GatewayStep {
  provider: string
  endpoint: string
  headers: Record<string, string>
  query: Record<string, unknown>
}

interface CompletionParams {
  messages: Array<{ role: string; content: string }>
  temperature?: number
  maxTokens?: number
  stream?: boolean
  preferredModel?: string  // Model preference hint (e.g., "qwen3-32b", "llama-3.3-70b")
}

// ---------------------------------------------------------------------------
// CN Direct providers — Direct API calls (NOT via AI Gateway)
//
// Priority based on speed and quality benchmarks:
// 1. GLM-4.7-Flash: 100.8 t/s, TTFT 0.96s, $0.07/M - Best balance
// 2. Qwen3.5-Flash: $0.10/M - Replaces deprecated Qwen-turbo
//
// Why direct calls?
// - Chinese providers have OpenAI-compatible APIs but with subtle differences
// - Cloudflare AI Gateway Custom Provider doesn't fully support these differences
// - Direct calls are faster and more reliable for CN/Asia users
//
// Trade-off:
// - ❌ No visibility in AI Gateway Dashboard
// - ✅ But we log timing and success/failure in Worker logs
// - ✅ Faster response time for CN/Asia users
//
// Future: If Cloudflare improves Custom Provider support, we can migrate back
// ---------------------------------------------------------------------------

const CN_DIRECT_PROVIDERS = [
  {
    name: 'glm-4.7-flash',
    envKey: 'ZHIPU_API_KEY' as const,
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    model: 'glm-4.7-flash',
    // Benchmark: 100.8 t/s, TTFT 0.96s, $0.07/M tokens - Most balanced
  },
  {
    name: 'qwen3.5-flash',
    envKey: 'ALIBABA_API_KEY' as const,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen3.5-flash',
    // Replaces deprecated qwen-turbo, $0.10/M tokens
  },
] as const

// ---------------------------------------------------------------------------
// AI Gateway providers — natively supported by CF AI Gateway
// ---------------------------------------------------------------------------

const GATEWAY_PROVIDERS = [
  {
    envKey: 'GROQ_API_KEY' as const,
    provider: 'groq',
    endpoint: 'chat/completions',
    model: 'qwen/qwen3-32b',  // Qwen3: better for Chinese, 400 t/s, cheaper
    modelHint: 'qwen3-32b',
    extraQuery: { reasoning_effort: 'none' },  // Disable <think> tags for faster response
  },
  {
    envKey: 'GROQ_API_KEY' as const,
    provider: 'groq',
    endpoint: 'chat/completions',
    model: 'llama-3.3-70b-versatile',  // Llama: better for English, 280 t/s, lower TTFT
    modelHint: 'llama-3.3-70b',
  },
  {
    envKey: 'GEMINI_API_KEY' as const,
    provider: 'google-ai-studio',
    endpoint: 'v1beta/chat/completions',
    model: 'gemini-3.1-flash-lite-preview',  // 500 RPD free tier!
  },
  {
    envKey: 'OPENROUTER_API_KEY' as const,
    provider: 'openrouter',
    endpoint: 'chat/completions',
    model: 'google/gemini-3.1-flash-lite-preview',
  },
  {
    envKey: 'DEEPSEEK_API_KEY' as const,
    provider: 'deepseek',
    endpoint: 'chat/completions',
    model: 'deepseek-chat',
  },
] as const

type AllEnvKeys =
  | (typeof CN_DIRECT_PROVIDERS)[number]['envKey']
  | (typeof GATEWAY_PROVIDERS)[number]['envKey']
type ProviderEnv = Partial<Record<AllEnvKeys, string>>

const CN_REGIONS = new Set(['CN', 'HK', 'MO', 'TW'])
const ASIA_REGIONS = new Set(['SG', 'MY', 'TH', 'ID', 'VN', 'PH', 'JP', 'KR']) // Southeast Asia + East Asia

// ---------------------------------------------------------------------------
// Gateway ordering
// ---------------------------------------------------------------------------

function getGatewayOrder(country?: string, preferredModel?: string): readonly string[] {
  // If user specifies preferred model, prioritize matching provider
  if (preferredModel) {
    const matchingProviders: string[] = []
    const otherProviders: string[] = []
    
    for (const provider of GATEWAY_PROVIDERS) {
      const hint = 'modelHint' in provider ? provider.modelHint : undefined
      if (hint && preferredModel.includes(hint as string)) {
        matchingProviders.push(`${provider.provider}:${provider.model}`)
      } else {
        otherProviders.push(`${provider.provider}:${provider.model}`)
      }
    }
    
    return [...matchingProviders, ...otherProviders, 'deepseek']
  }
  
  // Default: Qwen3 → Llama3.3 → Gemini → OpenRouter → DeepSeek
  return ['groq:qwen3-32b', 'groq:llama-3.3-70b', 'google-ai-studio', 'openrouter', 'deepseek']
}

export function getConfiguredProviders(env: ProviderEnv): string[] {
  const cnDirect = CN_DIRECT_PROVIDERS
    .filter(p => env[p.envKey])
    .map(p => p.name)
  const gateway = GATEWAY_PROVIDERS
    .filter(p => env[p.envKey])
    .map(p => p.provider)
  return [...cnDirect, ...gateway]
}

// ---------------------------------------------------------------------------
// Direct provider call (OpenAI-compatible fetch)
// ---------------------------------------------------------------------------

const DIRECT_CALL_TIMEOUT_MS = 1_500 // Fast fail for better UX

async function directComplete(
  provider: { name: string; baseUrl: string; model: string },
  apiKey: string,
  params: CompletionParams,
): Promise<Response | null> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), DIRECT_CALL_TIMEOUT_MS)

  try {
    const resp = await fetch(`${provider.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: provider.model,
        messages: params.messages,
        temperature: params.temperature,
        max_tokens: params.maxTokens,
        stream: params.stream ?? true,
      }),
      signal: controller.signal,
    })

    if (!resp.ok) {
      console.warn(`[DirectProvider] ${provider.name} returned ${resp.status}`)
      return null
    }

    return resp
  } catch (err) {
    console.warn(`[DirectProvider] ${provider.name} failed:`, err)
    return null
  } finally {
    clearTimeout(timer)
  }
}

// ---------------------------------------------------------------------------
// AI Gateway call - unified for all providers
// ---------------------------------------------------------------------------

function buildGatewaySteps(env: ProviderEnv, params: CompletionParams, country?: string): GatewayStep[] {
  const order = getGatewayOrder(country)

  const sorted = [...GATEWAY_PROVIDERS].sort(
    (a, b) => order.indexOf(a.provider) - order.indexOf(b.provider),
  )

  const steps: GatewayStep[] = []

  for (const cfg of sorted) {
    const apiKey = env[cfg.envKey]
    if (!apiKey) continue

    const queryParams: Record<string, unknown> = {
      model: cfg.model,
      messages: params.messages,
      temperature: params.temperature,
      max_tokens: params.maxTokens,
      stream: params.stream ?? true,
    }
    
    // Merge extra query params (e.g., reasoning_effort for Qwen3)
    if ('extraQuery' in cfg && cfg.extraQuery) {
      Object.assign(queryParams, cfg.extraQuery)
    }

    steps.push({
      provider: cfg.provider,
      endpoint: cfg.endpoint,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      query: queryParams,
    })
  }

  return steps
}

// ---------------------------------------------------------------------------
// Main entry: geo-aware hybrid completion
//
// CN/HK/MO/TW users (mainland China network):
//   → Direct (GLM-4.7-Flash → Qwen3.5-Flash) → AI Gateway (Groq → Gemini 3.1 Flash Lite → OpenRouter → DeepSeek)
// Other regions:
//   → AI Gateway (Groq → Gemini 3.1 Flash Lite → OpenRouter → DeepSeek)
//
// Free tier quotas:
// - Groq llama-3.3-70b: 1,000 RPD (completely free)
// - Gemini 3.1 Flash Lite: 500 RPD (15 RPM, free tier)
// - OpenRouter Gemini: 50 RPD (free tier backup)
// - DeepSeek: Paid fallback ($0.14/M input, $0.28/M output)
// ---------------------------------------------------------------------------

export async function gatewayComplete(
  aiBinding: Ai,
  env: ProviderEnv,
  params: CompletionParams,
  country?: string,
): Promise<Response> {
  const isCN = !!(country && CN_REGIONS.has(country))

  // Only CN/HK/MO/TW users try direct CN providers (fastest from mainland China)
  // Other Asia regions (SG, JP, etc.) skip direct calls and go straight to AI Gateway
  if (isCN) {
    const DIRECT_BUDGET_MS = 2_000 // Fast budget for better UX
    const directStart = Date.now()
    
    for (const provider of CN_DIRECT_PROVIDERS) {
      const apiKey = env[provider.envKey]
      if (!apiKey) continue

      if (Date.now() - directStart > DIRECT_BUDGET_MS) {
        console.log(`[AIGateway] direct budget exhausted (${Date.now() - directStart}ms), skipping to gateway`)
        break
      }

      console.log(`[AIGateway] country=${country}, trying direct: ${provider.name} (${provider.model})`)
      const t0 = Date.now()
      const resp = await directComplete(provider, apiKey, params)

      if (resp) {
        console.log(`[AIGateway] direct ${provider.name} connected in ${Date.now() - t0}ms`)
        return resp
      }

      console.log(`[AIGateway] direct ${provider.name} failed after ${Date.now() - t0}ms, continuing fallback`)
    }
  }

  // AI Gateway fallback
  const steps = buildGatewaySteps(env, params, country)

  if (steps.length === 0) {
    return new Response(
      JSON.stringify({ success: false, error: 'No AI provider configured' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    )
  }

  const order = steps.map(s => s.query.model || s.provider).join(' → ')
  console.log(`[AIGateway] country=${country || 'unknown'}, preferredModel=${params.preferredModel || 'default'}, gateway chain: ${order}`)

  const gateway = aiBinding.gateway(GATEWAY_ID)
  return gateway.run(steps) as unknown as Response
}
