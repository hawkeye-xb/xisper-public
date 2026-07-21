# Xisper — AI Agent Context Document

> Read this document FIRST before working on this codebase.
> This document provides all the context you need to understand the project, its architecture, and the planned work.

---

## 1. What is Xisper

Xisper is a **macOS menu bar app** for voice dictation. User presses a hotkey (Fn), speaks, and the transcribed text is automatically inserted into the currently focused application.

**Tech stack:** Electron + Vue 3 + TypeScript (frontend) | Cloudflare Workers + Hono (backend) | pnpm monorepo

**Core flow:**
```
User presses Fn → Audio recorded (16kHz PCM) → Streamed via WebSocket to Doubao ASR
→ Real-time transcription displayed → Recording stops → Optional LLM postprocess (DeepSeek)
→ Final text inserted into focused app via clipboard + Cmd+V
```

---

## 2. Monorepo Structure

```
Xisper/
├── apps/
│   ├── desktop/           # Electron app (main + preload + renderer entry)
│   │   └── src/main/      # Electron main process
│   │       ├── index.ts          # App entry, lifecycle, tray
│   │       ├── window.ts         # Window creation, ALL IPC handler registration
│   │       ├── hotkey/           # Global hotkey management (Fn key actions)
│   │       ├── input-writer/     # Text insertion via clipboard + robotjs
│   │       ├── database/         # SQLite via LowDB, transcription records
│   │       ├── audio-file-service.ts  # PCM audio file management
│   │       ├── auth-handler.ts   # OAuth deep link handling
│   │       ├── preferences.ts    # electron-store based preferences
│   │       ├── tray.ts           # System tray menu
│   │       ├── auto-updater/     # electron-updater
│   │       ├── webhook/          # Webhook notifications after transcription
│   │       └── i18n/             # Main process i18n (en, zh)
│   │
│   ├── web/               # Vue 3 frontend (loaded by Electron renderer)
│   │   └── src/
│   │       ├── views/
│   │       │   ├── LiveTranscribeView.vue  # CORE: Recording UI, ASR, postprocess orchestration
│   │       │   ├── HistoryView.vue         # Transcription history
│   │       │   ├── AnalyticsView.vue       # Usage statistics
│   │       │   ├── ScenariosView.vue       # Scenario presets
│   │       │   ├── DictionaryView.vue      # Hotwords management
│   │       │   ├── RecordingView.vue       # Manual recording
│   │       │   └── settings/               # Settings pages
│   │       ├── stores/                     # Pinia stores
│   │       │   ├── config.ts               # App config, feature flags
│   │       │   ├── recognition.ts          # ASR state, utterances
│   │       │   ├── llm-postprocess.ts      # LLM postprocess config
│   │       │   ├── scenarios.ts            # Scenario presets
│   │       │   └── hotwords.ts             # Hotword list
│   │       ├── composables/                # Vue composables
│   │       └── components/                 # Shared components
│   │
│   └── services/          # Cloudflare Workers backend
│       └── src/
│           ├── routes/    # API routes (auth, ASR proxy, LLM, quota)
│           └── services/  # Business logic
│
├── packages/
│   ├── fn-key-monitor/    # Rust + napi-rs: macOS Fn key detection via CGEventTap
│   ├── utils/             # Shared utilities
│   └── i18n-tools/        # i18n tooling
│
└── docs/
    ├── ASR-RECORDING-ARCHITECTURE.md  # Recording/transcription architecture doc
    └── AGENT_CONTEXT.md                # This file
```

---

## 3. Key Files You'll Touch Most

| File | Role | Lines |
|------|------|-------|
| `apps/desktop/src/main/window.ts` | **All IPC handlers are registered here.** New IPC channels go here. | ~910 |
| `apps/desktop/src/main/index.ts` | App lifecycle, tray, hotkey init. | ~523 |
| `apps/web/src/views/LiveTranscribeView.vue` | **The brain.** Recording orchestration, ASR, postprocess, UI. | ~690 |
| `apps/desktop/src/main/input-writer/writer.ts` | Text insertion. Uses robotjs + clipboard. | ~312 |
| `apps/desktop/src/main/hotkey/` | Hotkey system: action registry, manager, types. | multiple |
| `apps/web/src/stores/config.ts` | All app configuration and feature flags. | |
| `apps/web/src/stores/llm-postprocess.ts` | LLM postprocess settings, prompt config. | |

---

## 4. Native Module Architecture

### Current native modules:

1. **`@xisper/fn-key-monitor`** (Rust + napi-rs → `.node`)
   - Location: `packages/fn-key-monitor/`
   - Purpose: Monitor Fn key press/release via CGEventTap
   - API: `startMonitor(config, callback)`, `stopMonitor()`, `isMonitorRunning()`
   - Compiles to: `fn-key-monitor.darwin-arm64.node`

2. **`@jitsi/robotjs`** (C++ Node addon)
   - Third-party dependency
   - Purpose: Keyboard simulation (`keyTap`, `typeString`), used by InputWriter
   - Used in: `apps/desktop/src/main/input-writer/writer.ts`

### Planned native modules (use Swift + koffi):

New native code should be written as **Swift dynamic libraries (.dylib)** called from Node.js via **[koffi](https://koffi.dev/)** (FFI library).

Why koffi + Swift dylib instead of napi-rs:
- New modules need heavy macOS Accessibility API (AXUIElement) access
- Swift is the only first-class language for Apple's AX APIs
- dylib is decoupled from Node/Electron versions (no recompilation on upgrade)
- Typeless (competitor) has validated this approach in production with 5 Swift dylibs

koffi usage pattern:
```typescript
import koffi from 'koffi'

const lib = koffi.load('/path/to/libXisperContext.dylib')
const getFocusedAppInfo = lib.func('xisper_getFocusedAppInfo', 'str', [])

const result = JSON.parse(getFocusedAppInfo())
// { name: "Chrome", bundleId: "com.google.Chrome", pid: 12345 }
```

Swift dylib export pattern:
```swift
import Foundation
import ApplicationServices

@_cdecl("xisper_getFocusedAppInfo")
public func getFocusedAppInfo() -> UnsafePointer<CChar>? {
    let app = NSWorkspace.shared.frontmostApplication
    let json = """
    {"name":"\(app?.localizedName ?? "")","bundleId":"\(app?.bundleIdentifier ?? "")","pid":\(app?.processIdentifier ?? 0)}
    """
    return (json as NSString).utf8String
}
```

Planned new dylibs:
- `libXisperContext.dylib` — Read focused app info, window title, browser URL, selected text, visible text
- `libXisperInput.dylib` — Enhanced text insertion (rich text, selected text replacement)  
- `libXisperAudio.dylib` — System audio control (mute/unmute during recording)

---

## 5. Recording & Transcription Flow

Detailed architecture is in `docs/ASR-RECORDING-ARCHITECTURE.md`. Here's the summary:

```
┌─ Hotkey (Fn) detected by fn-key-monitor (Rust, CGEventTap) ──────────────┐
│                                                                            │
│  Main Process                          Renderer Process                    │
│  hotkey/manager.ts                     LiveTranscribeView.vue              │
│  → IPC 'hotkey:action-triggered'  →    onMounted: listen for hotkey events │
│                                        → coordinator.handleStart()         │
│                                        → AudioRecorder.startRecording()    │
│                                           (16kHz PCM, WebAudio API)        │
│                                        → WSManager.connect()               │
│                                           (wss://openspeech.bytedance.com) │
│                                        → Stream PCM chunks every 100ms     │
│                                        → Receive ASR results (utterances)  │
│                                        → Update UI in real-time            │
│                                                                            │
│  Fn released → coordinator.handleStop()                                    │
│             → Send last packet to ASR                                      │
│             → Wait for final result (3s timeout)                           │
│             → Optional: LLM postprocess (DeepSeek)                         │
│             → InputWriter.write(text) ──→  Main Process                    │
│                                            clipboard + Cmd+V paste         │
│             → Save to database                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

### ASR Config:
- Provider: **Doubao/Volcengine** (ByteDance)
- Endpoint: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`
- Audio: 16kHz, 16-bit, mono PCM
- Protocol: Custom binary (4-byte header + payload, optional gzip)

### LLM Postprocess:
- Provider: **DeepSeek** (via Cloudflare Worker proxy)
- Modes: `clean` (formatting only) / `rewrite` (full rewrite)
- Inputs: raw transcript + system prompt + hotwords + scenario role
- Fallback: if LLM fails/times out, use raw transcript

---

## 6. Competitive Analysis: Typeless

We reverse-engineered Typeless macOS v1.0.2 (Electron app). Key findings:

### Their architecture:
- **NOT streaming** — Records full audio, Opus-compresses to OGG, sends complete file to `api.typeless.com/ai/voice_flow`
- **One unified API** — `/ai/voice_flow` handles all modes via `mode` parameter
- **Server does everything** — ASR (likely Whisper) + LLM (likely GPT-4o-mini) + web search (Google Vertex AI)
- **5 native Swift dylibs** via koffi FFI

### Their three voice modes:
1. `voice_transcript` — Basic dictation (Fn)
2. `voice_command` — Edit selected text with voice instruction (select text + Fn)
3. `voice_translation` — Real-time translation (Fn+Shift)

### Their native capabilities (from `lib/` directory):
- `libContextHelper.dylib` — **Critical**: getFocusedAppInfo, getFocusedElementInfo, getFocusedVisibleText, getSelectedText, getFocusedElementRelatedContent
- `libInputHelper.dylib` — insertText, insertRichText, deleteBackward, getSelectedText
- `libKeyboardHelper.dylib` — Global keyboard monitoring, shortcut management
- `libUtilHelper.dylib` — System audio mute/unmute, app launching, lid detection
- `libopusenc_unified_macos.dylib` — Opus audio encoding

### Their database schema (from drizzle migrations):
- `history` table includes: `ax_text`, `ax_html` (accessibility context), `focused_app_name`, `focused_app_bundle_id`, `focused_app_window_title`, `focused_app_window_web_url`, `focused_app_window_web_domain`, `mode` (transcript/command/translation), `mode_meta`, `hasRevertedAI`

### Their settings (from electron-store schema):
- Shortcuts: `pushToTalk: "Fn"`, `handlesFreeMode: "Fn+Space"`, `pasteLastTranscript: "LeftCtrl+LeftCmd+V"`, `translationMode: "Fn+LeftShift"`
- Features: `enabledMuteBackgroundAudio`, `enabledOpusCompression`, `translationModeTargetLanguageCode`

### Their app data sent to server:
```
FormData to /ai/voice_flow:
  audio_id, mode, audio_file (OGG), audio_context (JSON with app/window/selected_text/visible_text),
  audio_metadata, parameters (selected_text for command, output_language for translation)

Response:
  { refine_text, delivery, user_prompt, web_metadata, external_action }
```

---

## 7. Feature Gap Summary

### Xisper has, Typeless doesn't:
- Streaming real-time ASR display (better UX during recording)
- Webhook integration
- Custom LLM prompts (user-editable)
- Scenario presets (manual + auto-switch)
- Audio file export / show in folder
- Analytics dashboard
- Linux support

### Typeless has, Xisper doesn't (= what we need to build):
| Feature | Priority | Dependency |
|---------|----------|------------|
| Context awareness (selected text, visible text, URL) | **Critical** | New Swift dylib |
| Voice Command mode (edit selected text) | **Critical** | Context + Enhanced InputWriter + LLM pipeline |
| Translation mode | High | LLM pipeline |
| Rich text / Markdown insertion | Medium | New Swift dylib |
| Auto-mute system audio during recording | Medium | Independent |
| Sound effects (start/stop recording) | Low | Independent |
| Paste last transcript shortcut | Low | Independent |
| AI undo (revert to raw transcript) | Medium | InputWriter |
| Web search grounding | Medium | LLM pipeline |
| Personalization (style learning) | Low | Server-side, needs history |
| Enhanced onboarding | Low | After features complete |

---

## 8. Planned Work (Task Breakdown)

Summary of planned work:

### Batch 0 (Independent, quick wins):
- **T9**: Auto-mute system audio during recording (AppleScript `set volume`)
- **T10**: Sound effects + paste-last-transcript shortcut

### Batch 1 (Foundation, parallel):
- **T1**: Native Context Bridge — Swift dylib via koffi for AXUIElement APIs
  - New dir: `packages/native-context/` (Swift) + `apps/desktop/src/main/context-bridge/` (Node wrapper)
  - Functions: getFocusedAppInfo, getWindowTitle, getWebInfo, getSelectedText, getVisibleText
  - macOS permissions: Accessibility (already have), Screen Recording (new)
  - **This is the critical path** — T4, T6, T12 all depend on it

- **T2**: Enhanced InputWriter
  - Add: `getSelectedText()`, `replaceSelectedText()`, `deleteBackward()`
  - File: `apps/desktop/src/main/input-writer/writer.ts`

- **T3**: Enhanced LLM Pipeline
  - Add multi-mode support: TRANSCRIPT / COMMAND / TRANSLATION
  - Add context injection into prompts
  - Files: stores, composables, services routes

### Batch 2 (Core features):
- **T4**: Voice Command mode (select text + speak instruction → LLM modifies → replace)
- **T5**: Translation mode (speak in language A → output in language B)
- **T6**: Context-aware postprocess (app-specific tone adaptation)

### Batch 3 (Enhancements):
- **T7**: AI undo
- **T8**: Web search grounding (Tavily API)

### Batch 4 (Polish):
- **T11**: Enhanced onboarding
- **T12**: Personalization

---

## 9. Technical Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| ASR engine | Keep Doubao streaming | Better real-time UX than Typeless's batch approach; DeepSeek handles cleanup |
| LLM engine | Keep DeepSeek | Cost-effective; good enough for postprocess; can upgrade later |
| New native modules | Swift + koffi (dylib) | Best macOS API access; proven by Typeless; Electron-version independent |
| Existing fn-key-monitor | Keep Rust + napi-rs | Already stable; no benefit from rewriting |
| robotjs | Keep for now | Works; can be replaced by Swift dylib in future (T2 phase 2) |
| Context collection timing | On hotkey press (main process) | Must capture before window focus changes |
| Translation target | Single target language setting | Matches Typeless UX; simpler than per-use selection |

---

## 10. Development Guidelines

- Vue 3 with TSX preferred over .vue files (user rule)
- Code comments, commits, and code-related content must be in English
- No multi-language i18n additions (user rule)
- No documentation files unless explicitly requested
- Use first principles thinking; consider context before acting
- Keep task execution within 3 steps when possible; if >5 steps needed, present plan first
