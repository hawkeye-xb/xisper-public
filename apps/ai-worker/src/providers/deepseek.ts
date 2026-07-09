import type { AIProvider, CompletionParams } from './types'

const DEEPSEEK_API_URL = 'https://api.deepseek.com/v1/chat/completions'
const DEFAULT_MODEL = 'deepseek-chat'

export class DeepSeekProvider implements AIProvider {
  readonly name = 'deepseek'
  private apiKey: string

  constructor(apiKey: string) {
    this.apiKey = apiKey
  }

  async complete(params: CompletionParams): Promise<Response> {
    return fetch(DEEPSEEK_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify({
        model: params.model || DEFAULT_MODEL,
        messages: params.messages,
        temperature: params.temperature,
        max_tokens: params.maxTokens,
        stream: params.stream ?? true,
      }),
    })
  }
}
