import type { AIProvider, CompletionParams } from './types'

export class FallbackChain {
  private providers: AIProvider[]

  constructor(providers: AIProvider[]) {
    this.providers = providers
  }

  async complete(params: CompletionParams): Promise<Response> {
    const errors: Array<{ provider: string; status?: number; message: string }> = []

    for (const provider of this.providers) {
      try {
        const response = await provider.complete(params)

        if (response.ok) {
          return response
        }

        // 4xx = client error, don't fallback — return directly
        if (response.status >= 400 && response.status < 500) {
          console.warn(`[FallbackChain] ${provider.name} returned ${response.status}, not retrying (client error)`)
          return response
        }

        // 5xx = server error, try next provider
        const errorText = await response.text()
        console.error(`[FallbackChain] ${provider.name} returned ${response.status}: ${errorText}`)
        errors.push({ provider: provider.name, status: response.status, message: errorText })
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        console.error(`[FallbackChain] ${provider.name} network error: ${message}`)
        errors.push({ provider: provider.name, message })
      }
    }

    return new Response(
      JSON.stringify({
        success: false,
        error: 'All providers failed',
        details: errors,
      }),
      { status: 502, headers: { 'Content-Type': 'application/json' } },
    )
  }
}
