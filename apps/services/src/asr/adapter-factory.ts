/**
 * ASR Adapter Factory
 *
 * Creates the appropriate ASR provider adapter based on geo-routing and model config.
 *
 * Geo-routing (primary):
 *   CN/HK/MO/TW  → Domestic adapter (Qwen3/Alibaba/Doubao, via ASR_MODEL env)
 *   Other regions → Soniox stt-rt-v4 (US, lowest latency for non-CN CF edges)
 *
 * Domestic model → Adapter mapping (prefix-based, via ASR_MODEL env):
 *   qwen3-asr-flash-realtime*  → Qwen3ASRAdapter
 *   fun-asr*                   → AlibabaAdapter (DashScope Fun-ASR)
 *   bigmodel*                  → DoubaoAdapter  (Volcengine BigASR)
 *
 * Fallback: if SONIOX_API_KEY is not configured, non-CN regions fall back
 * to the domestic adapter (slower but functional).
 */

import type { ASRProviderAdapter } from './types';
import { AlibabaAdapter } from './alibaba-adapter';
import { DoubaoAdapter } from './doubao-adapter';
import { Qwen3ASRAdapter } from './qwen3-asr-adapter';
import { SonioxAdapter } from './soniox-adapter';

const DEFAULT_MODEL = 'fun-asr-flash-8k-realtime';

const CN_REGIONS = new Set(['CN', 'HK', 'MO', 'TW']);

export function createASRAdapter(env: Record<string, any>, country?: string): ASRProviderAdapter {
  const isCN = !!(country && CN_REGIONS.has(country));

  // Non-CN: prefer Soniox for lowest latency from overseas CF edges.
  if (!isCN && env.SONIOX_API_KEY) {
    console.log(`[ASR Factory] country=${country || 'unknown'} → Soniox (overseas)`);
    return new SonioxAdapter();
  }

  // CN or Soniox unavailable: use domestic adapter based on ASR_MODEL.
  const model = (env.ASR_MODEL as string) || DEFAULT_MODEL;

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

  if (model.startsWith('bigmodel')) {
    return new DoubaoAdapter();
  }

  // Unknown model — fall back to Alibaba with a warning
  console.warn(`[ASR Factory] Unknown ASR_MODEL "${model}", falling back to AlibabaAdapter`);
  return new AlibabaAdapter();
}
