/**
 * ASR Adapter Factory
 *
 * Creates the appropriate ASR provider adapter based on geo-routing and model config.
 *
 * Geo-routing (primary):
 *   CN/HK/MO/TW  → Domestic adapter (Qwen3/Alibaba, via ASR_MODEL env)
 *   Other regions → Soniox stt-rt-v4 (US, lowest latency for non-CN CF edges)
 *
 * Domestic model → Adapter mapping (prefix-based, via ASR_MODEL env):
 *   qwen3-asr-flash-realtime*  → Qwen3ASRAdapter
 *   fun-asr*                   → AlibabaAdapter (DashScope Fun-ASR)
 *   scribe* / elevenlabs*      → ElevenLabsAdapter (Scribe v2 Realtime)
 *
 * Fallback: if SONIOX_API_KEY is not configured, non-CN regions fall back
 * to the domestic adapter (slower but functional).
 */

import type { ASRProviderAdapter } from './types';
import { AlibabaAdapter } from './alibaba-adapter';
import { ElevenLabsAdapter } from './elevenlabs-adapter';
import { Qwen3ASRAdapter } from './qwen3-asr-adapter';
import { SonioxAdapter } from './soniox-adapter';

const DEFAULT_MODEL = 'fun-asr-flash-8k-realtime';

const CN_REGIONS = new Set(['CN', 'HK', 'MO', 'TW']);

/**
 * Build a priority-ordered chain of adapters that support async file transcription.
 *
 * Used exclusively for the retranscribe fallback path: iterate adapters in order,
 * first successful `transcribeFile()` wins. Key existence determines inclusion.
 *
 * To add a new provider: import the adapter class, then add an `if (env.<KEY>)`
 * block in the desired position. No other file changes needed.
 */
export function createRetranscribeChain(env: Record<string, any>): ASRProviderAdapter[] {
  const chain: ASRProviderAdapter[] = [];

  // Priority: ElevenLabs (primary) → Soniox (backup)
  if (env.ELEVENLABS_API_KEY) {
    chain.push(new ElevenLabsAdapter());
  }
  if (env.SONIOX_API_KEY) {
    chain.push(new SonioxAdapter());
  }
  // Future: Alibaba file transcription
  // if (env.ALIBABA_API_KEY) {
  //   chain.push(new AlibabaAdapter());
  // }

  return chain;
}

export function createASRAdapter(env: Record<string, any>, country?: string): ASRProviderAdapter {
  const isCN = !!(country && CN_REGIONS.has(country));

  // If operator explicitly set ASR_MODEL_OVERRIDE or ASR_MODEL_SELECT, skip geo-routing entirely.
  // Non-CN default: Soniox for lowest latency from overseas CF edges.
  const isOperatorOverride = !!(env.ASR_MODEL_OVERRIDE || env.ASR_MODEL_SELECT);
  if (!isOperatorOverride && !isCN && env.SONIOX_API_KEY) {
    console.log(`[ASR Factory] country=${country || 'unknown'} → Soniox (overseas)`);
    return new SonioxAdapter();
  }

  // CN or Soniox unavailable: use domestic adapter based on ASR_MODEL.
  const model = ((env.ASR_MODEL_OVERRIDE || env.ASR_MODEL_SELECT || env.ASR_MODEL) as string) || DEFAULT_MODEL;

  if (!isCN && !env.SONIOX_API_KEY) {
    console.warn(`[ASR Factory] country=${country || 'unknown'} but SONIOX_API_KEY not set, falling back to domestic adapter`);
  }

  if (model.startsWith('qwen3-asr-flash-realtime')) {
    console.log(`[ASR Factory] country=${country || 'unknown'} → Qwen3-ASR (domestic)`);
    return new Qwen3ASRAdapter(model);
  }

  if (model.startsWith('fun-asr')) {
    return new AlibabaAdapter();
  }

  if ((model.startsWith('scribe') || model.startsWith('elevenlabs')) && env.ELEVENLABS_API_KEY) {
    console.log(`[ASR Factory] country=${country || 'unknown'} → ElevenLabs Scribe v2`);
    return new ElevenLabsAdapter();
  }

  // ElevenLabs model selected but API key not configured — warn and fall through.
  if (model.startsWith('scribe') || model.startsWith('elevenlabs')) {
    console.warn(`[ASR Factory] ELEVENLABS_API_KEY not configured, falling back to AlibabaAdapter`);
  }

  // Unknown model — fall back to Alibaba with a warning
  console.warn(`[ASR Factory] Unknown ASR_MODEL "${model}", falling back to AlibabaAdapter`);
  return new AlibabaAdapter();
}
