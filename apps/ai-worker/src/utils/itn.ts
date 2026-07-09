/**
 * Inverse Text Normalization (ITN) — rule-based, zero-latency.
 *
 * Converts Chinese spoken-form numbers to standard digit form before the
 * text is handed to the LLM prompt builder.
 *
 * Rules applied in order (to avoid conflicts):
 *   1. 百分之五十    → 50%
 *   2. 二零二四年    → 2024年   (year as four individual digit chars)
 *   3. 三月/十一日/三点半      (date/time with known unit suffix)
 *   4. 三百二十一    → 321      (compound numbers containing a unit char)
 *
 * Invariant: if the ASR server already emitted digits these patterns will
 * not match (they target Chinese character forms only).
 */

export function applyITN(text: string): string {
  let s = text
  s = normPercent(s)
  s = normYearDigits(s)
  s = normDateTimeUnits(s)
  s = normCompoundNumbers(s)
  return s
}

// ─── Rule 1: 百分之X → X% ───────────────────────────────────────────────────

function normPercent(text: string): string {
  return text.replace(
    /百分之([零一二三四五六七八九十百千万两点.\d]+)/g,
    (full, numStr: string) => {
      const val = parseAny(numStr)
      return val === null ? full : `${formatNum(val)}%`
    }
  )
}

// ─── Rule 2: 二零二四年 / 二〇二四年 → 2024年 ─────────────────────────────

function normYearDigits(text: string): string {
  return text.replace(
    /([零〇一二三四五六七八九]{4})年/g,
    (full, digits: string) => {
      const ds = [...digits].map(singleDigit)
      if (ds.some(d => d === null)) return full
      const year = ds[0]! * 1000 + ds[1]! * 100 + ds[2]! * 10 + ds[3]!
      return `${year}年`
    }
  )
}

// ─── Rule 3: Date/time unit suffixes ────────────────────────────────────────

const UNIT_RULES: Array<[string, number]> = [
  ['月',  12], ['日',  31], ['号',  31],
  ['点',  24], ['时',  24],
  ['分钟', 60], ['分',  60], ['秒',  60],
]

function normDateTimeUnits(text: string): string {
  let s = text
  for (const [suffix, maxVal] of UNIT_RULES) {
    const esc = suffix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    s = s.replace(
      new RegExp(`([零一二三四五六七八九十两]+)${esc}`, 'g'),
      (full, numStr: string) => {
        const v = parseCompound(numStr)
        if (v === null || v <= 0 || v > maxVal) return full
        return `${v}${suffix}`
      }
    )
  }
  return s
}

// ─── Rule 4: Compound numbers  e.g. 三百二十一 → 321 ───────────────────────

function normCompoundNumbers(text: string): string {
  return text.replace(
    /([零一二三四五六七八九十百千万亿两][零一二三四五六七八九十百千万亿两]+)/g,
    (matched) => {
      // Only convert if a multiplier char is present (avoids pure digit sequences)
      if (!/[十百千万亿]/.test(matched)) return matched
      const v = parseCompound(matched)
      return v === null ? matched : String(v)
    }
  )
}

// ─── Chinese number parser ──────────────────────────────────────────────────

function parseCompound(s: string): number | null {
  if (!s) return null
  return parseYi([...s])
}

function parseYi(cs: string[]): number | null {
  const idx = cs.lastIndexOf('亿')
  if (idx === -1) return parseWan(cs)
  const hi = cs.slice(0, idx).length === 0 ? 1 : parseWan(cs.slice(0, idx))
  if (hi === null) return null
  const after = cs.slice(idx + 1)
  const lo = after.length === 0 ? 0 : (parseYi(after) ?? 0)
  return hi * 100_000_000 + lo
}

function parseWan(cs: string[]): number | null {
  const idx = cs.lastIndexOf('万')
  if (idx === -1) return parseLT10k(cs)
  const hi = cs.slice(0, idx).length === 0 ? 1 : parseLT10k(cs.slice(0, idx))
  if (hi === null) return null
  const after = cs.slice(idx + 1)
  const lo = after.length === 0 ? 0 : (parseLT10k(after) ?? 0)
  return hi * 10_000 + lo
}

/** Parse number in range 0–9999. */
function parseLT10k(cs: string[]): number | null {
  if (cs.length === 0) return null
  let result = 0
  let pending: number | null = null
  let start = 0

  // Implicit leading 1 for 十 at start (十五 = 15, not 1*10+5)
  if (cs[0] === '十') { result = 10; start = 1 }

  for (let i = start; i < cs.length; i++) {
    switch (cs[i]) {
      case '零': case '〇': pending = 0;  break
      case '一':  { const r = setDigit(pending, 1); if (r < 0) return null; pending = r; break }
      case '二':  { const r = setDigit(pending, 2); if (r < 0) return null; pending = r; break }
      case '两':  { const r = setDigit(pending, 2); if (r < 0) return null; pending = r; break }
      case '三':  { const r = setDigit(pending, 3); if (r < 0) return null; pending = r; break }
      case '四':  { const r = setDigit(pending, 4); if (r < 0) return null; pending = r; break }
      case '五':  { const r = setDigit(pending, 5); if (r < 0) return null; pending = r; break }
      case '六':  { const r = setDigit(pending, 6); if (r < 0) return null; pending = r; break }
      case '七':  { const r = setDigit(pending, 7); if (r < 0) return null; pending = r; break }
      case '八':  { const r = setDigit(pending, 8); if (r < 0) return null; pending = r; break }
      case '九':  { const r = setDigit(pending, 9); if (r < 0) return null; pending = r; break }
      case '十':  result += (pending ?? 1) * 10;   pending = null; break
      case '百':  result += (pending ?? 1) * 100;  pending = null; break
      case '千':  result += (pending ?? 1) * 1000; pending = null; break
      default:    return null
    }
  }
  if (pending !== null && pending > 0) result += pending
  return result
}

/** Returns -1 (invalid sentinel) if consecutive non-zero digits detected. */
function setDigit(pending: number | null, digit: number): number {
  if (pending !== null && pending !== 0) return -1
  return digit
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Parse a value that may be Chinese (三百) or Arabic (300), with optional
 *  decimal using 点  (八十五点六 → 85.6). */
function parseAny(s: string): number | null {
  const n = parseFloat(s)
  if (!isNaN(n)) return n
  const dotIdx = s.indexOf('点')
  if (dotIdx !== -1) {
    const iv = parseCompound(s.slice(0, dotIdx))
    if (iv === null) return null
    const fracDigits = [...s.slice(dotIdx + 1)].map(singleDigit)
    if (fracDigits.some(d => d === null)) return null
    return iv + parseFloat('0.' + fracDigits.join(''))
  }
  return parseCompound(s)
}

function singleDigit(c: string): number | null {
  const MAP: Record<string, number> = {
    '零': 0, '〇': 0, '0': 0,
    '一': 1, '1': 1,
    '二': 2, '2': 2,
    '三': 3, '3': 3,
    '四': 4, '4': 4,
    '五': 5, '5': 5,
    '六': 6, '6': 6,
    '七': 7, '7': 7,
    '八': 8, '8': 8,
    '九': 9, '9': 9,
  }
  return MAP[c] ?? null
}

function formatNum(v: number): string {
  return Number.isInteger(v) ? String(v) : String(v)
}
