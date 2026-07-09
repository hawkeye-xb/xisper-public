import {
  MODE_PLACEHOLDER,
  ALLOWED_OPERATIONS_PLACEHOLDER,
  HOTWORDS_PLACEHOLDER,
  CORRECTIONS_PLACEHOLDER,
  CONTEXT_PLACEHOLDER,
  CONTEXT_DIRECTIVE_PLACEHOLDER,
  TRANSLATION_PLACEHOLDER,
  IDENTITY_CONTEXT_PLACEHOLDER,
} from './templates'
import type { PostprocessRequest } from '../routes/postprocess'

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export interface BuildPromptOutput {
  messages: ChatMessage[]
  hotwordsProvided: string[]
}

// ---------------------------------------------------------------------------
// Selected-text prompt with intent detection (command / replace / dictate)
// Reference: CommandExecutor from voice-input-web
// ---------------------------------------------------------------------------

const SELECTED_TEXT_PROMPT = `Voice input with selected text. Clean the spoken input (remove fillers, fix ASR errors), then detect intent:
1. command — instruction to transform selected text → apply it, output result
2. replace — new content replacing selection → output cleaned speech
3. dictate — unrelated to selection → output cleaned speech
Output ONLY the final text. No explanations.

Examples:
[Selected] "Hello world" [Voice] 嗯把这个翻译成中文 → 你好世界
[Selected] "项目进度：已完成" [Voice] um make it more professional → Project Status: Completed
[Selected] "第一点 第二点 第三点" [Voice] 格式化成列表 → 1. 第一点\n2. 第二点\n3. 第三点`

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function uniqNonEmpty(items: string[] | undefined): string[] {
  if (!items || items.length === 0) return []
  const seen = new Set<string>()
  const out: string[] = []
  for (const raw of items) {
    const t = (raw ?? '').trim()
    if (!t || seen.has(t)) continue
    seen.add(t)
    out.push(t)
  }
  return out
}

function collapseBlankLines(text: string): string {
  return (text ?? '').replace(/\n{3,}/g, '\n\n').trim()
}

function buildCorrectionsBlock(corrections?: PostprocessRequest['corrections']): string {
  if (!corrections || corrections.length === 0) return ''
  const lines = corrections.map((r) => {
    if (r.misheard?.length) {
      return r.misheard.map(m => `"${m}" → "${r.correct}"`).join(', ')
    }
    return `→ "${r.correct}"`
  })
  return ['Known ASR errors (apply when context matches):', ...lines].join('\n')
}

function injectTemplate(
  template: string,
  blocks: Array<{ placeholder: string; content: string }>,
): string {
  let out = template
  const appended: string[] = []

  for (const b of blocks) {
    const content = (b.content ?? '').trim()
    if (out.includes(b.placeholder)) {
      out = out.split(b.placeholder).join(content)
    } else if (content) {
      appended.push(content)
    }
  }

  if (appended.length > 0) {
    out = `${out.trimEnd()}\n\n${appended.join('\n\n')}`
  }

  return collapseBlankLines(out)
}

function hasSelectedText(ctx?: PostprocessRequest['context']): boolean {
  return !!(ctx?.selectedText && ctx.selectedText.trim().length > 0)
}

function buildIdentityContextBlock(identityContext?: string): string {
  if (!identityContext || !identityContext.trim()) return ''
  return [
    `## User Domain: ${identityContext.trim()}`,
    'ASR is error-prone when speakers mix languages. A word that looks wrong in one language is often a phonetic rendering of a term from another language common in this domain.',
    'Read the full sentence, infer what the speaker meant given their domain, and output the natural form a domain professional would actually type.',
    'Preserve the original meaning — only fix words that are clearly ASR artifacts, not intentional speech.',
  ].join('\n')
}

function buildContextBlock(ctx?: PostprocessRequest['context']): string {
  if (!ctx) return ''
  const lines: string[] = []
  if (ctx.app?.name) lines.push(`Active app: ${ctx.app.name}`)
  if (ctx.windowTitle) lines.push(`Window title: ${ctx.windowTitle}`)
  if (ctx.url) lines.push(`URL: ${ctx.url}`)
  if (ctx.domain) lines.push(`Domain: ${ctx.domain}`)
  if (ctx.selectedText) lines.push(`Selected text: ${ctx.selectedText}`)
  if (ctx.visibleText) lines.push(`Focused element text:\n${ctx.visibleText}`)
  if (ctx.windowText) lines.push(`Window visible content:\n${ctx.windowText}`)
  if (lines.length === 0) return ''
  return [
    'Application context (reference signal only — describes the environment around the speaker, NOT the content to process). Your task is to clean the ASR transcript above; use this block only to disambiguate words. Do not let it pull the output toward the topic of the active app, window, or selection.',
    ...lines,
  ].join('\n')
}

/** Behavior rule: no selection = dictation only; with selection = may apply instruction to selection. */
function buildContextDirective(hasSelectedText: boolean): string {
  if (hasSelectedText) {
    return [
      'Selected text is provided. The user may be speaking an instruction about this selection (e.g. "format this", "translate to English").',
      'If the transcript is such an instruction, output the result of applying it to the selected text. Otherwise output only the cleaned transcript.',
    ].join(' ')
  }
  return [
    'No selection. Pure dictation mode: only clean and format the transcript. Do not change the original meaning.',
    'Do not answer, interpret, or respond to the content; output only the cleaned/formatted text the user said.',
  ].join(' ')
}

// ---------------------------------------------------------------------------
// Command prompt builder (selectedText present)
// ---------------------------------------------------------------------------

function buildCommandPrompt(
  req: PostprocessRequest,
  hotwords: string[],
): BuildPromptOutput {
  let systemPrompt = SELECTED_TEXT_PROMPT

  const identityContextBlock = buildIdentityContextBlock(req.identityContext)
  if (identityContextBlock) {
    systemPrompt += '\n\n' + identityContextBlock
  }

  if (hotwords.length > 0 && req.config.features.hotwords) {
    systemPrompt += '\n\nDomain vocabulary (prefer when context supports): ' +
      hotwords.map((w) => `"${w}"`).join(', ')
  }

  const correctionsBlock = buildCorrectionsBlock(req.corrections)
  if (correctionsBlock) {
    systemPrompt += '\n\n' + correctionsBlock
  }

  const ctxLines: string[] = []
  if (req.context?.app?.name) ctxLines.push(`Active app: ${req.context.app.name}`)
  if (req.context?.windowTitle) ctxLines.push(`Window title: ${req.context.windowTitle}`)
  if (ctxLines.length > 0) {
    systemPrompt += '\n\n' + ctxLines.join('\n')
  }

  const userContent = [
    '[Selected Text]',
    '<<<',
    req.context!.selectedText!,
    '>>>',
    '',
    '[Voice Input]',
    '<<<',
    req.text,
    '>>>',
  ].join('\n')

  return {
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userContent },
    ],
    hotwordsProvided: hotwords,
  }
}

// ---------------------------------------------------------------------------
// Standard dictation prompt builder (no selectedText)
// ---------------------------------------------------------------------------

function buildDictationPrompt(
  req: PostprocessRequest,
  template: string,
  hotwords: string[],
): BuildPromptOutput {
  const config = req.config
  const allowRewrite = config.mode === 'rewrite' && config.features.rewrite

  const capabilityLines: string[] = []
  if (config.features.correction) capabilityLines.push('- Correct recognition errors.')
  if (config.features.formatting) capabilityLines.push('- Add punctuation and line breaks when helpful.')
  if (config.features.hotwords && hotwords.length > 0)
    capabilityLines.push('- Use domain vocabulary to correct ASR misrecognitions based on context.')
  if (allowRewrite)
    capabilityLines.push('- Rewrite for clarity and fluency while keeping the original meaning.')

  const modeBlock =
    config.mode === 'clean'
      ? 'Mode: CLEAN. Only do correction, punctuation, segmentation, and formatting. Do not rewrite or paraphrase.'
      : allowRewrite
        ? 'Mode: REWRITE. You may rewrite/paraphrase for readability, but must preserve meaning and all factual details.'
        : 'Mode: REWRITE (disabled). Treat as CLEAN.'

  const allowedOpsBlock =
    capabilityLines.length > 0 ? ['Allowed operations:', ...capabilityLines].join('\n') : ''

  const hotwordsBlock =
    hotwords.length > 0 && config.features.hotwords
      ? [
          'Domain vocabulary (prefer these terms when context supports — ASR may produce similar-sounding alternatives):',
          hotwords.map((w) => `- ${w}`).join('\n'),
        ].join('\n')
      : ''

  const correctionsBlock = buildCorrectionsBlock(req.corrections)
  const identityContextBlock = buildIdentityContextBlock(req.identityContext)
  const contextBlock = buildContextBlock(req.context)
  const contextDirectiveBlock = buildContextDirective(false)

  const systemPrompt = injectTemplate(template, [
    { placeholder: IDENTITY_CONTEXT_PLACEHOLDER, content: identityContextBlock },
    { placeholder: MODE_PLACEHOLDER, content: modeBlock },
    { placeholder: ALLOWED_OPERATIONS_PLACEHOLDER, content: allowedOpsBlock },
    { placeholder: HOTWORDS_PLACEHOLDER, content: hotwordsBlock },
    { placeholder: CORRECTIONS_PLACEHOLDER, content: correctionsBlock },
    { placeholder: CONTEXT_DIRECTIVE_PLACEHOLDER, content: contextDirectiveBlock },
    { placeholder: CONTEXT_PLACEHOLDER, content: contextBlock },
  ])

  const userContent = ['Input transcript:', '<<<', req.text ?? '', '>>>'].join('\n')

  const messages: ChatMessage[] = [
    { role: 'system', content: systemPrompt },
    { role: 'user', content: userContent },
  ]

  return { messages, hotwordsProvided: hotwords }
}

// ---------------------------------------------------------------------------
// Translation prompt builder
// ---------------------------------------------------------------------------

function buildTranslationPrompt(
  req: PostprocessRequest,
  template: string,
  hotwords: string[],
): BuildPromptOutput {
  const translationBlock = req.translationInstruction
    ? `Translation rules:\n${req.translationInstruction}`
    : 'If the text is in Chinese, translate to English.\nIf the text is in English, translate to Chinese.\nOtherwise, translate to English.'

  const hotwordsBlock =
    hotwords.length > 0
      ? 'Domain vocabulary (prefer when context supports): ' +
        hotwords.map((w) => `"${w}"`).join(', ')
      : ''

  const correctionsBlock = buildCorrectionsBlock(req.corrections)
  const identityContextBlock = buildIdentityContextBlock(req.identityContext)
  const contextDirectiveBlock = buildContextDirective(false)

  const systemPrompt = injectTemplate(template, [
    { placeholder: IDENTITY_CONTEXT_PLACEHOLDER, content: identityContextBlock },
    { placeholder: TRANSLATION_PLACEHOLDER, content: translationBlock },
    { placeholder: HOTWORDS_PLACEHOLDER, content: hotwordsBlock },
    { placeholder: CORRECTIONS_PLACEHOLDER, content: correctionsBlock },
    { placeholder: CONTEXT_DIRECTIVE_PLACEHOLDER, content: contextDirectiveBlock },
  ])

  const userContent = ['Translate the following transcript:', '<<<', req.text ?? '', '>>>'].join('\n')

  return {
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userContent },
    ],
    hotwordsProvided: hotwords,
  }
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export function buildPostprocessPrompt(
  req: PostprocessRequest,
  template: string,
): BuildPromptOutput {
  const hotwords = uniqNonEmpty(req.hotwords)
  const voiceMode = req.config.voiceMode || 'dictation'

  // Selected text present → always use intent detection (command/replace/dictate),
  // regardless of voiceMode. The spoken input acts as an instruction on the selected text.
  if (hasSelectedText(req.context)) {
    console.log(`[Builder] Selected text detected (${req.context!.selectedText!.length} chars), voiceMode=${voiceMode}, using command prompt`)
    return buildCommandPrompt(req, hotwords)
  }

  // No selected text → route by voiceMode
  if (voiceMode === 'translation') {
    console.log(`[Builder] Translation mode (no selection), textLen=${req.text.length}`)
    return buildTranslationPrompt(req, template, hotwords)
  }

  return buildDictationPrompt(req, template, hotwords)
}
