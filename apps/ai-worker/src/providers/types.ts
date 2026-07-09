export interface CompletionParams {
  messages: Array<{ role: string; content: string }>
  model?: string
  temperature?: number
  maxTokens?: number
  stream?: boolean
}

export interface AIProvider {
  readonly name: string
  complete(params: CompletionParams): Promise<Response>
}
