import { getDefaultTemplate, type VoiceMode } from './templates'

export interface StoredTemplate {
  template: string
  version: string
  updatedAt: string
  updatedBy: string
}

export interface LoadedTemplate {
  template: string
  version: string
  source: 'kv' | 'default'
}

const KV_KEY_PREFIX = 'prompt_template:'

export function kvKey(voiceMode: string): string {
  return `${KV_KEY_PREFIX}${voiceMode}`
}

/**
 * Load prompt template from KV, falling back to hardcoded default.
 */
export async function loadTemplate(
  kv: KVNamespace,
  voiceMode: VoiceMode,
): Promise<LoadedTemplate> {
  try {
    const stored = await kv.get<StoredTemplate>(kvKey(voiceMode), 'json')
    if (stored?.template) {
      return {
        template: stored.template,
        version: stored.version || 'kv',
        source: 'kv',
      }
    }
  } catch (err) {
    console.warn(`[TemplateStore] Failed to load from KV for ${voiceMode}:`, err)
  }

  return {
    template: getDefaultTemplate(voiceMode),
    version: 'default',
    source: 'default',
  }
}
