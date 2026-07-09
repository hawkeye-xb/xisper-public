# Xisper Feature Parity Plan — Typeless 功能追齐方案

> 基于对 Typeless macOS v1.0.2 客户端的逆向分析，制定 Xisper 功能追齐计划。
> 
> 策略：保持现有 Doubao 流式 ASR + DeepSeek LLM 后处理，优先补齐基础能力差距。

---

## 一、竞品分析摘要

### 1.1 Typeless 核心架构

通过对 Typeless 客户端 app.asar 的逆向分析，其核心架构如下：

```
客户端录音 → Opus 压缩 OGG → api.typeless.com/ai/voice_flow (FormData)
                                        ↓
                               ┌─────────────────────┐
                               │  ASR (Whisper API)   │
                               │  LLM (GPT-4o-mini)  │
                               │  Search (Vertex AI)  │
                               └─────────────────────┘
                                        ↓
                               { refine_text, delivery, web_metadata, external_action }
```

**关键发现：**

- 所有智能处理在服务端完成，客户端只做录音、上下文采集、文本插入
- 统一 `/ai/voice_flow` 接口，通过 `mode` 字段区分三种模式
- 5 个原生 Swift dylib 通过 koffi (FFI) 调用，提供系统级能力
- React + Electron + Vite + drizzle ORM

### 1.2 Typeless 原生模块清单

| 模块 | 文件 | 能力 |
|------|------|------|
| **ContextHelper** | `libContextHelper.dylib` | getFocusedAppInfo, getFocusedElementInfo, getFocusedVisibleText, getFocusedElementRelatedContent, setFocusedWindowEnhancedUserInterface |
| **InputHelper** | `libInputHelper.dylib` | insertText, insertRichText, deleteBackward, getSelectedText, getCurrentInputState |
| **KeyboardHelper** | `libKeyboardHelper.dylib` | updateTargetShortcuts, resetPressingKeycodes, 全局快捷键监听 |
| **UtilHelper** | `libUtilHelper.dylib` | testDeviceListLatency, testAudioLatency, launchApplicationByName, muteAudio, unmuteAudio, isAudioMuted, deviceIsLidOpen |
| **OpusEncoder** | `libopusenc_unified_macos.dylib` | Opus 音频编码 |

### 1.3 Typeless 三种语音模式

| 模式 | mode 值 | 触发方式 | 核心逻辑 |
|------|---------|----------|----------|
| **听写** | `voice_transcript` | Fn（按住说话） | 语音 → ASR → LLM 润色 → 插入到焦点应用 |
| **指令** | `voice_command` | 选中文本 + Fn | 获取选中文本 + 语音指令 → LLM 按指令修改 → 替换选中文本 |
| **翻译** | `voice_translation` | Fn+Shift | 语音 → ASR → LLM 翻译为目标语言 → 插入 |

### 1.4 Xisper 当前状态

> **最后更新**：2026-02-26

| 能力 | 现状 | 对标 Typeless |
|------|------|---------------|
| 流式 ASR (Doubao/Alibaba) | ✅ 已实现 | 多 ASR 适配器架构（Doubao + Alibaba），体验更好 |
| LLM 后处理 (多模型) | ✅ 已实现 | AI Gateway 多 Provider 容灾（Groq → Gemini → DeepSeek），KV 模板管理 |
| 文本插入 + 替换 | ✅ 已实现 | write + replaceSelectedText + deleteBackward 均已实现 |
| 上下文感知（选中文本、可见文本、URL） | ✅ 已实现 | Swift dylib + koffi FFI，完整 AX API 能力 |
| 上下文驱动后处理 | ✅ 已实现 | Context 注入 prompt，app/URL/visibleText 驱动输出风格 |
| 录音静音系统音频 | ✅ 已实现 | AudioController + 设置开关 |
| 声音反馈 | ✅ 已实现 | Web Audio API 音效（录音开始/结束/错误） |
| Hotwords/词典 | ✅ 已实现 | 功能等价 |
| 历史记录 + 音频保存 | ✅ 已实现 | Xisper 更强（有音频回放、文件导出） |
| 使用分析 (Analytics) | ✅ 已实现 | Xisper 更强（有本地统计图表） |
| Webhook 集成 | ✅ 已实现 | Typeless 无此功能，Xisper 独有优势 |
| 快捷键系统 | ✅ 已实现 | 全新模块化架构（parser/validator/matcher/capture mode） |
| 语音编辑选中文本 | ✅ 已实现 | Command 模式 FN+C，CommandExecutor 生成命令，支持选中文本上下文 |
| 翻译模式 | ✅ 已实现 | FN+T 触发翻译模式，ASR → LLM 翻译，支持目标语言设置 |
| 粘贴上次转写快捷键 | ✅ 已实现 | 代码就绪，注释待启用 |
| 富文本/Markdown 插入 | ❌ 缺失 | insertRichText (Phase 2) |
| ~~AI 撤销~~ | 已移除 | MVP 阶段不做，用户可 Cmd+Z 撤销 |
| ~~联网搜索~~ | 已移除 | 偏离核心，不做 |
| ~~个性化学习~~ | 已移除 | 偏离核心，不做 |

---

## 二、整体架构设计

### 2.1 目标架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Renderer Process (Vue)                       │
│                                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐             │
│  │ LiveTranscri│  │  VoiceCommand │  │ VoiceTranslat │             │
│  │   beView    │  │     View      │  │    ionView    │             │
│  └──────┬──────┘  └───────┬───────┘  └───────┬───────┘             │
│         │                 │                   │                     │
│  ┌──────┴─────────────────┴───────────────────┴──────┐             │
│  │            RecordingCoordinator (enhanced)         │             │
│  │  + modeManager: VoiceMode (transcript/command/     │             │
│  │                             translation)           │             │
│  │  + contextCollector: ContextCollector              │             │
│  └──────┬─────────────────┬──────────────────────────┘             │
│         │                 │                                         │
│  ┌──────┴──────┐  ┌──────┴──────┐                                  │
│  │AudioRecorder│  │  WSManager  │                                  │
│  └─────────────┘  └─────────────┘                                  │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ IPC
┌──────────────────────────┴──────────────────────────────────────────┐
│                        Main Process (Electron)                      │
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│  │  ContextBridge   │  │  InputWriter    │  │  AudioController │   │
│  │  (NEW)          │  │  (Enhanced)     │  │  (NEW)           │   │
│  │                 │  │                 │  │                  │   │
│  │ getFocusedApp   │  │ write()         │  │ muteSystem()     │   │
│  │ getSelectedText │  │ insertRichText()│  │ unmuteSystem()   │   │
│  │ getVisibleText  │  │ replaceSelected │  │ isSystemMuted()  │   │
│  │ getWindowTitle  │  │   Text()        │  │                  │   │
│  │ getWebInfo      │  │ getSelectedText │  └──────────────────┘   │
│  │ getRelatedCtx   │  │   ()            │                         │
│  └─────────────────┘  └─────────────────┘                         │
│          │                    │                                     │
│  ┌───────┴────────────────────┴──────────────────────────────┐     │
│  │              Native Bridge (koffi FFI)                     │     │
│  │  Decision: Swift dylib + koffi for ALL new native code.    │     │
│  │  Rationale:                                                │     │
│  │  - Swift = first-class macOS API access (AXUIElement etc.) │     │
│  │  - dylib decoupled from Electron version (no recompile)    │     │
│  │  - Typeless validated this approach (5 Swift dylibs)       │     │
│  │  - Existing fn-key-monitor (Rust+napi-rs) stays as-is      │     │
│  │                                                            │     │
│  │  ┌────────────────────┐  ┌─────────────────────────────┐  │     │
│  │  │ libXisperContext   │  │ libXisperInput              │  │     │
│  │  │  .dylib (Swift)    │  │  .dylib (Swift)             │  │     │
│  │  │                    │  │                             │  │     │
│  │  │ AXUIElement API    │  │ AXUIElement API             │  │     │
│  │  │ CGWindow API       │  │ NSPasteboard               │  │     │
│  │  │ NSWorkspace        │  │ CGEvent (key simulation)    │  │     │
│  │  └────────────────────┘  └─────────────────────────────┘  │     │
│  └────────────────────────────────────────────────────────────┘     │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │              Existing Modules (Unchanged)                 │      │
│  │  HotkeyManager | Database | Auth | Tray | AutoUpdater   │      │
│  └──────────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    Services (Cloudflare Workers)                     │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐                               │
│  │  ASR Proxy   │  │  LLM Proxy   │                               │
│  │  (Doubao)    │  │  (DeepSeek)  │                               │
│  │  Unchanged   │  │  Enhanced    │                               │
│  └──────────────┘  └──────────────┘                               │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 新增 IPC 通道设计

```typescript
// Context Bridge IPC Channels
'context:get-focused-app'         // → { name, bundleId, pid }
'context:get-window-title'        // → string
'context:get-web-info'            // → { url, domain, title } | null
'context:get-selected-text'       // → string | null
'context:get-visible-text'        // → string | null
'context:get-related-content'     // → string | null
'context:collect-full'            // → FullContext (all above combined)

// Enhanced InputWriter IPC Channels
'input:write'                     // existing
'input:write-rich-text'           // → NEW: insert formatted text
'input:get-selected-text'         // → NEW: get currently selected text
'input:replace-selected-text'     // → NEW: replace selected text with new text
'input:delete-backward'           // → NEW: delete N characters backward

// Audio Controller IPC Channels
'audio:mute-system'               // → NEW: mute system audio
'audio:unmute-system'             // → NEW: restore system audio
'audio:is-system-muted'           // → NEW: check mute state

// Voice Mode IPC Channels
'voice:set-mode'                  // → NEW: switch voice mode
'voice:get-mode'                  // → NEW: get current mode
```

### 2.3 数据库 Schema 变更

```sql
-- history 表新增字段
ALTER TABLE records ADD COLUMN mode TEXT DEFAULT 'voice_transcript';
ALTER TABLE records ADD COLUMN mode_meta TEXT;           -- JSON: mode-specific metadata
ALTER TABLE records ADD COLUMN focused_app_name TEXT;
ALTER TABLE records ADD COLUMN focused_app_bundle_id TEXT;
ALTER TABLE records ADD COLUMN focused_app_window_title TEXT;
ALTER TABLE records ADD COLUMN focused_app_web_url TEXT;
ALTER TABLE records ADD COLUMN focused_app_web_domain TEXT;
ALTER TABLE records ADD COLUMN ax_text TEXT;              -- accessibility visible text
ALTER TABLE records ADD COLUMN has_reverted_ai INTEGER DEFAULT 0;
ALTER TABLE records ADD COLUMN raw_transcript TEXT;       -- original ASR output before LLM
ALTER TABLE records ADD COLUMN audio_context TEXT;        -- full context JSON snapshot
ALTER TABLE records ADD COLUMN client_metadata TEXT;      -- device/app version info
```

---

## 三、任务拆分

### T1: 原生上下文感知模块 (ContextBridge)

> **为什么做**：这是 Typeless 最核心的差异化能力。上下文信息让 LLM 后处理能根据当前使用场景（代码编辑器 vs 邮件 vs 聊天工具）自动适配输出风格。它也是 Voice Command（语音编辑选中文本）的前提——不能获取选中文本，就无法实现语音编辑。

**当前状态**：`active-app.ts` 只通过 AppleScript 获取 app name 和 bundle ID，无法获取窗口标题、网页 URL、选中文本、可见文本。

**目标**：构建一个原生 Swift 动态库，通过 macOS Accessibility API 获取丰富的上下文信息。

#### T1.1 原生 Swift 动态库 (libXisperContext.dylib)

**实现方式**：Swift Package 编译为 .dylib，通过 koffi (FFI) 从 Node.js 调用。

```swift
// Public C-compatible API surface
@_cdecl("xisper_getFocusedAppInfo")
public func getFocusedAppInfo() -> UnsafePointer<CChar>?
// Returns JSON: { "name": "...", "bundleId": "...", "pid": 123 }

@_cdecl("xisper_getWindowTitle")
public func getWindowTitle() -> UnsafePointer<CChar>?
// Returns the title of the focused window

@_cdecl("xisper_getWebInfo")
public func getWebInfo() -> UnsafePointer<CChar>?
// Returns JSON: { "url": "...", "domain": "...", "title": "..." } or null
// Works with Safari, Chrome, Arc, Firefox via AX API

@_cdecl("xisper_getSelectedText")
public func getSelectedText() -> UnsafePointer<CChar>?
// Returns the currently selected text in any app via AX API

@_cdecl("xisper_getVisibleText")
public func getVisibleText() -> UnsafePointer<CChar>?
// Returns visible text near the cursor/focused element

@_cdecl("xisper_getRelatedContent")
public func getRelatedContent() -> UnsafePointer<CChar>?
// Returns surrounding content (paragraph, chat messages, etc.)

@_cdecl("xisper_collectFullContext")
public func collectFullContext() -> UnsafePointer<CChar>?
// Collects everything above in one call, returns unified JSON
```

**核心 macOS API 使用**：

| 信息 | API | 权限需求 |
|------|-----|----------|
| App name, Bundle ID, PID | `NSWorkspace.shared.frontmostApplication` | 无（已有） |
| Window title | `AXUIElementCopyAttributeValue(kAXTitleAttribute)` | Accessibility |
| Selected text | `AXUIElementCopyAttributeValue(kAXSelectedTextAttribute)` | Accessibility |
| Focused element value | `AXUIElementCopyAttributeValue(kAXValueAttribute)` | Accessibility |
| Browser URL | `AXUIElementCopyAttributeValue` on address bar element | Accessibility |
| Visible text | `AXUIElementCopyAttributeValue(kAXVisibleCharacterRangeAttribute)` | Accessibility |

**浏览器 URL 获取策略**：

```
Safari:    AXWebArea → AXDocument → URL attribute
Chrome:    AXGroup → AXTextField (address bar) → AXValue
Arc:       Similar to Chrome (Chromium-based)
Firefox:   AXGroup → AXTextField → AXValue
Fallback:  Window title parsing (most browsers include URL/page title)
```

#### T1.2 Node.js ContextBridge 封装

```typescript
// apps/desktop/src/main/context-bridge/index.ts

interface FocusedAppInfo {
  name: string
  bundleId: string
  pid: number
}

interface WebInfo {
  url: string
  domain: string
  title: string
}

interface FullContext {
  app: FocusedAppInfo
  windowTitle: string | null
  web: WebInfo | null
  selectedText: string | null
  visibleText: string | null
  relatedContent: string | null
  collectedAt: number  // timestamp
}

class ContextBridge {
  private lib: any  // koffi loaded library

  async getFocusedApp(): Promise<FocusedAppInfo>
  async getWindowTitle(): Promise<string | null>
  async getWebInfo(): Promise<WebInfo | null>
  async getSelectedText(): Promise<string | null>
  async getVisibleText(): Promise<string | null>
  async getRelatedContent(): Promise<string | null>
  async collectFull(): Promise<FullContext>
}
```

#### T1.3 App/URL 白名单与黑名单

某些应用/网站不应读取上下文（如密码管理器、银行网站），需要配置黑名单：

```typescript
interface ContextConfig {
  enableContextCollection: boolean
  appBlacklist: string[]       // bundle IDs to skip
  appWhitelist: string[]       // bundle IDs where extra context is safe
  urlBlacklistDomains: string[] // domains to skip (banking, auth pages)
  urlBlacklistPrefixes: string[] // URL prefixes to skip
}

// Default blacklist
const DEFAULT_APP_BLACKLIST = [
  'com.apple.keychainaccess',   // Keychain
  'com.1password.1password',    // 1Password
  'com.bitwarden.desktop',      // Bitwarden
]

const DEFAULT_URL_BLACKLIST_DOMAINS = [
  'accounts.google.com',
  'login.microsoftonline.com',
  'bank',  // fuzzy match
]
```

#### T1.4 权限管理

```
需要的 macOS 权限：
├── Accessibility (辅助功能) — 已有，用于全局快捷键
│   └── 现在还需要用于：AXUIElement API (选中文本、可见文本等)
│
├── Automation (自动化) — 已有，用于 AppleScript
│   └── 将被 T1 的原生 AX API 部分替代
│
└── Screen Recording (屏幕录制) — 新增
    └── 部分 AX 信息需要此权限（如浏览器 URL 在某些情况下）
    └── 在 PermissionsSetup 页面中增加引导
```

**文件变更清单**：
- 新增 `packages/native-context/` — Swift Package（dylib 源码）
- 新增 `apps/desktop/src/main/context-bridge/` — Node.js 封装 + IPC handlers
- 修改 `apps/desktop/src/main/window.ts` — 注册新 IPC handlers
- 修改 `apps/web/src/views/PermissionsSetup.vue` — 增加 Screen Recording 权限引导
- 修改 `apps/desktop/build/entitlements.mac.plist` — 如需新 entitlement

---

### T2: 增强 InputWriter

> **为什么做**：Voice Command 模式需要"获取选中文本 → 语音修改 → 替换选中文本"的能力。当前 InputWriter 只能 append 文本，不能操作选中文本。同时 Typeless 支持 Markdown/富文本插入，我们也需要补齐。

**当前状态**：`input-writer/writer.ts` 使用 `@jitsi/robotjs` 做键盘模拟 + 剪贴板粘贴，仅支持纯文本 append。

#### T2.1 获取选中文本

两种实现路径：

**路径 A（推荐）**：通过 T1 的 `ContextBridge.getSelectedText()` 获取
- 优点：复用 AX API，不影响剪贴板
- 缺点：依赖 T1 完成

**路径 B（备选）**：Cmd+C 复制到剪贴板再读取
- 优点：简单，不依赖 T1
- 缺点：会覆盖用户剪贴板（需要保存/恢复）

```typescript
// Enhanced InputWriter API
class InputWriter {
  // Existing
  async write(text: string, options?: WriteOptions): Promise<WriteResult>

  // New methods
  async getSelectedText(): Promise<string | null>
  async replaceSelectedText(newText: string): Promise<WriteResult>
  async deleteBackward(charCount: number): Promise<boolean>
  async insertRichText(html: string): Promise<WriteResult>  // Phase 2
}
```

#### T2.2 替换选中文本

```typescript
async replaceSelectedText(newText: string): Promise<WriteResult> {
  // 1. Verify there's selected text (optional, via AX API)
  // 2. Save clipboard
  // 3. Write new text to clipboard
  // 4. Cmd+V to paste (replaces selection natively)
  // 5. Restore clipboard
}
```

这个实现很简单——macOS 的原生行为就是：有选中文本时，粘贴会替换选中内容。所以只需要确保选中状态没有丢失即可。

#### T2.3 富文本插入（Phase 2）

需要原生 Swift 实现，因为 `NSPasteboard` 支持设置多种格式：

```swift
// In libXisperInput.dylib
@_cdecl("xisper_insertRichText")
public func insertRichText(html: UnsafePointer<CChar>) -> Bool {
    let htmlString = String(cString: html)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(htmlString, forType: .html)
    // Simulate Cmd+V
    // ...
}
```

**文件变更清单**：
- 修改 `apps/desktop/src/main/input-writer/writer.ts` — 新增方法
- 修改 `apps/desktop/src/main/input-writer/types.ts` — 新增类型
- 修改 `apps/desktop/src/main/window.ts` — 注册新 IPC handlers
- 新增 `packages/native-input/` — Swift Package（Phase 2, 富文本）

---

### T2.5: 写入失败检测 (InputWriter + AX API)

> **为什么做**：当前 `InputWriter` 通过 clipboard + Cmd+V 写入文本，但**无法检测写入是否成功**。如果用户点在桌面空白处（没有聚焦任何输入框），Cmd+V 被 macOS 静默忽略，但 `InputWriter` 仍返回 `success: true`。现有的 `verifyPaste` 通过检查剪贴板变化来判断，但大多数 app 粘贴后不修改剪贴板，所以不可靠。

**当前方案的问题**：

```
clipboard.writeText(text) → Cmd+V → sleep(150ms) → 检查剪贴板有没有变化
                                                     ↑ 不可靠：大多数 app 不修改剪贴板
```

**解决方案**：利用已有的 `contextBridge` Swift dylib 的 AX API 能力，在写入**之前**检查焦点元素是否可编辑。

#### T2.5.1 Swift 侧新增 API

```swift
// packages/native-context/Sources/XisperContext/Context.swift

@_cdecl("xisper_isFocusedEditable")
public func isFocusedEditable() -> Bool {
    guard let element = getAXFocusedElement() else { return false }
    
    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""
    
    let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    if editableRoles.contains(roleStr) { return true }
    
    // Check for contenteditable web elements (AXWebArea with editable flag)
    var isEditable: AnyObject?
    if AXUIElementCopyAttributeValue(element, "AXIsEditable" as CFString, &isEditable) == .success {
        return (isEditable as? Bool) ?? false
    }
    
    return false
}
```

#### T2.5.2 InputWriter 集成

```typescript
// In InputWriter.write(), before clipboard + paste:
const editable = contextBridge.isFocusedEditable()
if (!editable) {
  return {
    success: false,
    method: 'clipboard',
    charsWritten: 0,
    error: 'No editable input field focused',
  }
}
```

#### T2.5.3 前端处理

当 `WriteResult.success === false` 且 `error` 包含 "No editable input field" 时，前端应给出明确的用户提示（toast / 音效），而不是静默失败。

**文件变更清单**：
- 修改 `packages/native-context/Sources/XisperContext/Context.swift` — 新增 `xisper_isFocusedEditable()`
- 修改 `apps/desktop/src/main/context-bridge/index.ts` — 暴露 `isFocusedEditable()`
- 修改 `apps/desktop/src/main/input-writer/writer.ts` — 写入前检查
- 修改 `apps/web/src/views/LiveTranscribeView.vue` — 写入失败 UI 提示

---

### T3: 增强 LLM 后处理管线

> **为什么做**：当前 LLM 后处理只有一个简单的 clean/rewrite 模式。要支持 Voice Command（按指令修改选中文本）和 Voice Translation（翻译），需要让 LLM 管线支持多模式 + 上下文注入。

**当前状态**：后处理通过 DeepSeek API 实现，有 system prompt + hotwords 注入。

#### T3.1 多模式后处理

```typescript
enum VoiceMode {
  TRANSCRIPT = 'voice_transcript',    // Default: ASR → LLM refine → insert
  COMMAND = 'voice_command',          // Selected text + voice instruction → LLM modify → replace
  TRANSLATION = 'voice_translation',  // ASR → LLM translate → insert
}

interface PostprocessRequest {
  mode: VoiceMode
  rawTranscript: string              // ASR output
  context?: {
    app: FocusedAppInfo
    windowTitle?: string
    web?: WebInfo
    selectedText?: string            // For COMMAND mode
    visibleText?: string
    relatedContent?: string
  }
  parameters?: {
    outputLanguage?: string          // For TRANSLATION mode
    userInstruction?: string         // For COMMAND mode (= rawTranscript)
  }
  hotwords?: string[]
  scenario?: ScenarioConfig
}

interface PostprocessResponse {
  refinedText: string
  rawTranscript: string
  mode: VoiceMode
  webMetadata?: any
}
```

#### T3.2 模式 Prompt 模板

**TRANSCRIPT 模式**（增强版）：

```
System: You are a voice dictation assistant. The user is speaking into {app_name}
{if web_url: on the webpage {web_url}}. 
Clean up the transcription: fix punctuation, remove filler words, 
format properly for the context.

{if scenario: Role: {scenario.role}}
{if hotwords: Important vocabulary: {hotwords.join(', ')}}
{if visible_text: For context, the user is currently looking at: "{visible_text_excerpt}"}

User: {raw_transcript}
```

**COMMAND 模式**：

```
System: The user has selected the following text and will give a voice command 
to modify it. Apply ONLY the requested change. Return the modified text only, 
with no explanation.

Selected text:
"""
{selected_text}
"""

{if visible_text: Surrounding context: "{visible_text_excerpt}"}

User command: {raw_transcript}
```

**TRANSLATION 模式**：

```
System: Translate the user's speech into {target_language}. 
Output only the translation, in a natural and native style. 
Maintain the original tone and intent.

{if visible_text: Context (for reference): "{visible_text_excerpt}"}

User's speech: {raw_transcript}
```

#### T3.3 上下文注入流程

```
录音开始
    ↓
ContextBridge.collectFull() ← 在录音开始时采集一次
    ↓ (存入 session.context)
录音中... (ASR 流式处理)
    ↓
录音结束
    ↓
postprocessRequest = {
  mode: currentMode,
  rawTranscript: asrResult,
  context: session.context,    ← 注入上下文
  parameters: modeParams,
  hotwords: hotwordList,
  scenario: matchedScenario,
}
    ↓
LLM API call (DeepSeek)
    ↓
refinedText → 写入 / 替换
```

#### T3.4 服务端 LLM Proxy 增强

```typescript
// apps/services/src/routes/llm.ts (Cloudflare Worker)

// New endpoint or enhanced existing endpoint
POST /api/v1/llm/postprocess

Request Body: {
  mode: 'voice_transcript' | 'voice_command' | 'voice_translation',
  raw_transcript: string,
  context: {
    app_name: string,
    app_bundle_id: string,
    window_title?: string,
    web_url?: string,
    web_domain?: string,
    selected_text?: string,     // For command mode
    visible_text?: string,
    related_content?: string,
  },
  parameters: {
    output_language?: string,   // For translation
  },
  hotwords: string[],
  scenario?: { name: string, system_prompt: string },
  user_id: string,
}

Response: {
  refined_text: string,
  mode: string,
  debug?: { prompt_tokens: number, completion_tokens: number },
}
```

**文件变更清单**：
- 修改 `apps/web/src/composables/` 或 `apps/web/src/services/` — 后处理逻辑增强
- 修改 `apps/web/src/stores/llm-postprocess.ts` — 支持多模式
- 修改 `apps/services/src/routes/` — LLM proxy 增强
- 新增 `apps/web/src/constants/prompt-templates.ts` — Prompt 模板

---

### T4: 语音编辑选中文本 (Voice Command 模式)

> **为什么做**：用户选中一段文本，按快捷键说出指令（如"改成正式语气"、"缩短一半"），LLM 按指令修改并替换原文。让语音从"输入工具"升级为"编辑工具"。

**依赖**：T1（getSelectedText）、T2（replaceSelectedText）、T3（COMMAND mode）

**当前状态**：✅ 已实现
- ✅ LLM command prompt：`CommandExecutor` 服务，语音 → shell 命令生成，支持 `selectedText` 上下文
- ✅ 上下文采集：`LiveTranscribeView.vue` 录音开始时通过 `collectPostprocessContext()` 采集 `selectedText`；main process 通过 `contextBridge.getSelectedText()` 异步捕获并通过 `hotkey:context-update` IPC 传递
- ✅ 替换能力：`InputWriter.replaceSelectedText()` 已实现
- ✅ **独立快捷键**：`command` action，默认 `FN+C`
- ✅ **提交路径**：`LiveTranscribeView.vue` 中 `isCommandMode` 分支 → `doCommandPostprocess()` → `CommandExecutor` → `inputWriter.write()` 追加命令输出
- ❌ **模式 UI**：Floating bar 尚无 Command Mode 视觉指示（Phase 2）

#### T4.1 已完成工作

- ✅ `CommandExecutor` 服务（`apps/web/src/services/llm-postprocess/command-executor.ts`）：语音 → shell 命令生成，支持 `selectedText` 上下文注入
- ✅ `LiveTranscribeView.vue` 中 `isCommandMode` 分支 → `doCommandPostprocess()`
- ✅ 独立快捷键 `command`（默认 `FN+C`），通过 `createToggleCallback` 工厂注册
- ✅ Main process 通过 `contextBridge.getSelectedText()` 异步捕获选中文本
- ✅ FN 消歧修复：Release-based `fnComboUsed` 标志替代 timer-based 方案
- ✅ 校验器修复：FN+modifier 组合（如 FN+LeftShift）合法化
- ✅ `resetToDefault` 冲突解决

#### T4.2 剩余工作（Phase 2）

- Floating bar 增加 Command 模式视觉指示
- 无选中文本时提示用户先选中

---

### T5: 翻译模式 (Voice Translation)

> **为什么做**：实时语音翻译是高价值功能，尤其对跨语言工作场景（写英文邮件、翻译文档）非常实用。实现成本相对较低，主要是在现有 LLM 管线中增加翻译 prompt。

**依赖**：T3（TRANSLATION mode prompt）

#### T5.1 交互流程

```
1. 用户在设置中选择目标翻译语言（如 English）
2. 在任意应用的输入框中
3. 按下翻译快捷键（如 Fn+Shift）
4. Floating bar 显示 "🌐 Translation → English"
5. 用户用母语说话
6. 松开快捷键
7. ASR 识别语音（原语言 raw transcript）
8. LLM 翻译为目标语言
9. 翻译结果插入到焦点应用
```

#### T5.2 配置项

```typescript
interface TranslationConfig {
  targetLanguage: string      // ISO language code: 'en', 'zh', 'ja', 'ko', etc.
  hotkey: string              // Default: 'Fn+LeftShift'
  preserveFormatting: boolean // Keep original text structure
}

const SUPPORTED_TRANSLATION_LANGUAGES = [
  { code: 'en', name: 'English' },
  { code: 'zh', name: '中文' },
  { code: 'ja', name: '日本語' },
  { code: 'ko', name: '한국어' },
  { code: 'es', name: 'Español' },
  { code: 'fr', name: 'Français' },
  { code: 'de', name: 'Deutsch' },
  { code: 'pt', name: 'Português' },
  { code: 'ru', name: 'Русский' },
  // ...
]
```

#### T5.3 实现要点

- 复用现有录音 + ASR 流程
- 只需在 `postprocessTextChunk` 中根据 mode 切换 prompt
- 翻译质量高度依赖 LLM（DeepSeek 的多语言翻译质量不错，但如果不满意可以替换为 GPT-4o-mini）
- 存入数据库时同时保存原文和译文

**文件变更清单**：
- 新增 `apps/desktop/src/main/hotkey/action-types.ts` — 增加 voice-translation action
- 修改 `apps/web/src/views/LiveTranscribeView.vue` — 增加 translation 模式处理
- 修改 `apps/web/src/stores/config.ts` — 翻译配置
- 新增 `apps/web/src/views/settings/TranslationSettings.vue`（或 TSX）— 翻译设置页

---

### T6: 上下文感知智能后处理

> **为什么做**：这是将上下文信息（T1）和 LLM 管线（T3）串联起来的关键步骤。让语音听写的输出根据当前使用场景自动适配——在 Slack 中口语化，在邮件中正式化，在代码编辑器中输出指令格式。

**依赖**：T1 + T3

#### T6.1 上下文采集时机

```
┌────────────────────────────────────────────────────┐
│  快捷键按下 (main process)                          │
│  ↓                                                  │
│  contextBridge.collectFull()   ← 立即采集           │
│  ↓                                                  │
│  将 context 通过 IPC 传给 renderer                  │
│  ↓                                                  │
│  录音开始 (renderer process)                        │
│  ↓                                                  │
│  ASR 流式处理中...                                  │
│  ↓                                                  │
│  录音结束                                           │
│  ↓                                                  │
│  postprocess({                                      │
│    rawTranscript,                                    │
│    context,          ← 使用录音开始时采集的上下文    │
│    mode,                                            │
│    ...                                              │
│  })                                                 │
└────────────────────────────────────────────────────┘
```

#### T6.2 上下文驱动的 Prompt 适配

```typescript
function buildContextAwarePrompt(context: FullContext, mode: VoiceMode): string {
  const parts: string[] = []

  // Base role
  parts.push('You are a voice dictation assistant.')

  // App context
  if (context.app) {
    const appCategory = categorizeApp(context.app.bundleId)
    switch (appCategory) {
      case 'code-editor':
        parts.push('The user is dictating in a code editor. Output technical, precise language.')
        break
      case 'email':
        parts.push('The user is composing an email. Use professional, polished language.')
        break
      case 'chat':
        parts.push('The user is in a chat app. Keep the tone casual and conversational.')
        break
      case 'document':
        parts.push('The user is writing a document. Use well-structured, formal language.')
        break
    }
  }

  // Web context
  if (context.web) {
    parts.push(`The user is on: ${context.web.title} (${context.web.domain})`)
  }

  // Visible text context (truncated)
  if (context.visibleText) {
    const excerpt = context.visibleText.substring(0, 500)
    parts.push(`For context, the nearby text reads: "${excerpt}"`)
  }

  return parts.join('\n')
}

function categorizeApp(bundleId: string): string {
  const categories: Record<string, string[]> = {
    'code-editor': [
      'com.microsoft.VSCode', 'com.todesktop.230313mzl4w4u92', // Cursor
      'dev.zed.Zed', 'com.sublimetext.4', 'com.jetbrains.*',
    ],
    'email': [
      'com.apple.mail', 'com.google.Chrome', // Gmail detection via URL
      'com.microsoft.Outlook',
    ],
    'chat': [
      'com.tinyspeck.slackmacgap', 'com.tencent.xinWeChat',
      'com.hnc.Discord', 'ru.keepcoder.Telegram',
    ],
    'document': [
      'com.apple.iWork.Pages', 'com.microsoft.Word',
      'com.google.Chrome', // Google Docs detection via URL
      'md.obsidian',
    ],
  }
  // ... match logic with wildcard support
}
```

#### T6.3 与现有场景系统的关系

当前 Xisper 已有场景预设系统（Scenarios）：默认风格、Cursor 指令、会议纪要等。上下文感知不是替代场景系统，而是补充：

- **场景系统**：用户手动选择或按 app 自动匹配 → 使用预设的 system prompt
- **上下文感知**：自动注入上下文信息到 prompt → 让 LLM 更了解当前环境

两者叠加：场景提供"角色设定"，上下文提供"环境信息"。

**文件变更清单**：
- 修改 `apps/web/src/composables/` — 录音流程中注入上下文采集
- 修改 `apps/web/src/stores/config.ts` — 上下文感知开关 + 黑白名单配置
- 修改 `apps/web/src/views/settings/` — 上下文设置页

---

### ~~T7: AI 撤销 (Revert AI Edit)~~ — 已移除

> **移除原因**：MVP 阶段不做。用户可通过 Cmd+Z 撤销 AI 插入的文本，无需额外实现。如未来有强需求再评估。

---

### ~~T8: 联网搜索 Grounding~~ — 已移除

> **移除原因**：联网搜索本质是 AI Agent 能力，偏离语音听写/编辑的产品核心。当前阶段聚焦核心语音交互能力，不做通用 AI 问答。如未来需要，可作为独立功能单独评估。

---

### T9: 录音时自动静音系统音频

> **为什么做**：用户在录音时，如果电脑正在播放音乐/视频，会被麦克风捕获影响识别质量。Typeless 在录音开始时自动静音、结束时恢复。简单但体验提升明显。

**无依赖**，可独立实现。

#### T9.1 macOS 实现

```typescript
// apps/desktop/src/main/audio-controller.ts

import { exec } from 'child_process'

class AudioController {
  private previousVolume: number | null = null
  private wasMuted: boolean = false

  async muteSystem(): Promise<void> {
    // Save current state
    const { stdout: volumeStr } = await execAsync(
      'osascript -e "output volume of (get volume settings)"'
    )
    this.previousVolume = parseInt(volumeStr.trim())

    const { stdout: muteStr } = await execAsync(
      'osascript -e "output muted of (get volume settings)"'
    )
    this.wasMuted = muteStr.trim() === 'true'

    // Mute
    if (!this.wasMuted) {
      await execAsync('osascript -e "set volume with output muted"')
    }
  }

  async unmuteSystem(): Promise<void> {
    // Restore previous state
    if (!this.wasMuted && this.previousVolume !== null) {
      await execAsync('osascript -e "set volume without output muted"')
    }
    this.previousVolume = null
    this.wasMuted = false
  }
}
```

#### T9.2 配置项

```typescript
// In preferences
interface AudioConfig {
  muteSystemDuringRecording: boolean  // Default: true
}
```

**文件变更清单**：
- 新增 `apps/desktop/src/main/audio-controller.ts`
- 修改 `apps/desktop/src/main/window.ts` — 注册 IPC handlers
- 修改 `apps/web/src/views/LiveTranscribeView.vue` — 录音开始/结束时调用
- 修改 `apps/web/src/views/settings/` — 设置项

---

### T10: 声音反馈 + 粘贴上次转写快捷键

> **为什么做**：声音反馈让用户确认录音已开始/结束，不需要看屏幕。粘贴上次转写快捷键是高频需求——用户经常需要在另一个地方再次粘贴上次的语音输入结果。

**无依赖**，可独立实现。

#### T10.1 声音反馈

```typescript
// Renderer process - play sound via Web Audio API or <audio> element
const SOUNDS = {
  recordingStart: '/static/sounds/recording-start.wav',
  recordingStop: '/static/sounds/recording-stop.wav',
  commandMode: '/static/sounds/command-mode.wav',
  error: '/static/sounds/error.wav',
}

function playSound(sound: keyof typeof SOUNDS) {
  if (!configStore.enableSoundEffects) return
  const audio = new Audio(SOUNDS[sound])
  audio.volume = 0.3
  audio.play().catch(() => {}) // ignore if blocked
}
```

#### T10.2 粘贴上次转写快捷键

```typescript
// New hotkey action
const PASTE_LAST_TRANSCRIPT_ACTION = {
  id: 'paste-last-transcript',
  defaultKey: 'LeftCtrl+LeftCmd+V',  // Same as Typeless
  description: 'Paste last transcription result',
}

// Handler in main process
hotkeyManager.onAction('paste-last-transcript', async () => {
  const lastRecord = await db.getLatestRecord()
  if (lastRecord?.transcribeContent) {
    await inputWriter.write(lastRecord.transcribeContent)
  }
})
```

**文件变更清单**：
- 新增 `apps/web/src/assets/sounds/` — 音效文件
- 修改 `apps/web/src/views/LiveTranscribeView.vue` — 播放音效
- 修改 `apps/desktop/src/main/hotkey/` — 注册新快捷键
- 修改 `apps/web/src/stores/config.ts` — 音效开关
- 修改 `apps/web/src/views/settings/` — 设置项

---

### ~~T11: 增强 Onboarding~~ — 已移除

> **移除原因**：简单出一个文档即可，不需要代码实现。

---

### ~~T12: 个性化学习（服务端）~~ — 已移除

> **移除原因**：服务端 style profiling 复杂度高、收益不确定，且依赖大量用户数据积累。当前阶段聚焦核心语音交互体验，个性化可通过现有的场景预设（Scenarios）和 Hotwords 机制部分满足。

---

## 四、依赖关系图

```
                  ┌──────────────────────────────┐
                  │ T1: Native Context Bridge     │ ← ✅ DONE
                  │ (Swift dylib + Node wrapper)  │
                  └──────┬──────────┬─────────────┘
                         │          │
              ┌──────────┘          └──────────────┐
              │                                    │
              ▼                                    ▼
┌─────────────────────┐              ┌─────────────────────┐
│ T2: Enhanced        │ ← ✅ DONE    │ T3: Enhanced LLM    │ ← ✅ DONE
│     InputWriter     │              │     Pipeline        │
│ (replace, richtext) │              │ (multi-mode, ctx)   │
└──────┬──────────────┘              └──────┬──────────────┘
       │                                    │
       │         ┌─────────────┐            │
       └────────►│ T4: Voice   │◄───────────┘
                 │   Command   │ ← ✅ DONE
                 └──────┬──────┘
                        │
                        ▼
              ~~T7: AI Undo~~ — 已移除

              ┌─────────────────┐
     T3 ────►│ T5: Translation │ ← ✅ DONE
              └─────────────────┘

     T1 + T3 ──►┌──────────────────┐
                 │ T6: Context-Aware│ ← ✅ DONE
                 │    Postprocess   │
                 └──────────────────┘

     (Independent)
     ┌────────────────┐  ┌───────────────────┐
     │ T9: Auto Mute  │  │ T10: Sound + Paste│
     │    ✅ DONE      │  │     Last Shortcut  │
     └────────────────┘  └───────────────────┘

     T2 ──────►┌─────────────────────┐
               │ T2.5: Write Failure │ (AX API pre-check)
               │      Detection      │
               └─────────────────────┘

     ~~T7: AI Undo~~ — 已移除
     ~~T8: Web Search~~ — 已移除
     ~~T11: Onboarding~~ — 已移除（出文档即可）
     ~~T12: Personalization~~ — 已移除
```

---

## 五、执行计划

### 5.1 并行批次

| 批次 | 任务 | 说明 | 预估工作量 | 状态 |
|------|------|------|------------|------|
| **Batch 0** | T9, T10 | 独立小功能，先出可感知的成果 | 各 1-2 天 | ✅ 全部完成 |
| **Batch 1** | T1, T2, T3 | 基础设施层，可完全并行 | T1: 5-7 天, T2: 2-3 天, T3: 3-4 天 | ✅ 全部完成 |
| **Batch 2** | T2.5, T4, T5 | 核心功能层 | T2.5: 1 天, T4: 1-2 天, T5: 2 天 | ❌ T2.5 未开始, ✅ T4 完成, ✅ T5 完成 |
| **~~Batch 3~~** | ~~T7~~ | ~~AI 撤销~~ | ~~T7: 1-2 天~~ | 🗑 已移除 |

### 5.2 进度甘特图（截至 2026-02-26）

```
                  Done                        TODO
─────────────────────────────────────────────────────────────
T9  [██████████] ✅
T10 [██████████] ✅
T1  [██████████] ✅
T2  [██████████] ✅
T3  [██████████] ✅
T6  [██████████] ✅
T4  [██████████] ✅ (CommandExecutor + FN+C + selectedText)
T5  [██████████] ✅ (FN+T + translate store + LLM 翻译)
T2.5 ─────────── [████] 写入失败检测 (AX API pre-check)
     ~~T7  AI 撤销~~ 已移除
─────────────────────────────────────────────────────────────
     ~~T8  联网搜索~~ 已移除
     ~~T11 Onboarding~~ 已移除
     ~~T12 个性化~~ 已移除
```

### 5.3 里程碑

| 里程碑 | 完成条件 | 状态 |
|--------|----------|------|
| **M0: Quick Wins** | T9 + T10 完成：录音静音、音效反馈、粘贴上次转写 | ✅ 完成 |
| **M1: Foundation Ready** | T1 + T2 + T3 完成：能采集上下文、能操作选中文本、LLM 管线支持多模式 | ✅ 完成 |
| **M2: Core Parity** | T2.5 + T4 + T5 + T6 完成：写入失败检测、Voice Command、翻译模式、上下文感知后处理 | ⚠️ 80% — T4/T5/T6 完成, T2.5 待做 |
| **~~M3: Release Ready~~** | ~~T7 完成：AI 撤销~~ | 🗑 已移除 |

---

## 六、技术风险与缓解

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|----------|
| Swift dylib 编译与 Electron 集成问题 | 阻塞 T1 | 中 | 先做最小 POC（只实现 getFocusedAppInfo），验证 koffi 调用链路 |
| AX API 权限问题，不同 app 行为不一致 | T1 部分功能不可用 | 高 | 逐个 app 测试，维护兼容性矩阵，不支持的 app 优雅降级 |
| 浏览器 URL 获取在不同浏览器中的差异 | T1.getWebInfo 部分失效 | 高 | 优先支持 Safari + Chrome，其他浏览器通过 window title fallback |
| 选中文本在快捷键触发时丢失 | T4 核心功能受影响 | 中 | 在 main process hotkey callback 中立即采集，不等 renderer |
| DeepSeek 翻译质量不满足期望 | T5 用户体验差 | 中 | 准备 GPT-4o-mini 作为备选，或让用户选择模型 |
| 富文本插入在不同应用中行为不一致 | T2 部分功能 | 高 | Phase 2 实现，先用纯文本 + Markdown 符号 |

---

## 七、验收标准

### T1 验收 ✅ DONE
- [x] 能获取所有常用 app 的 name + bundleId（与 AppleScript 等价）
- [x] 能获取 Chrome/Safari 的当前 URL 和页面标题
- [x] 能获取任意文本编辑器中的选中文本
- [x] 能获取焦点输入框周围的可见文本
- [ ] 无 Accessibility 权限时优雅降级，不影响核心功能
- [ ] 性能：collectFull() < 100ms

### T2 验收 ✅ DONE
- [x] getSelectedText() 能正确获取选中文本
- [x] replaceSelectedText() 能替换选中文本
- [x] 不破坏原有的 write() 功能
- [ ] 剪贴板正确保存和恢复

### T3 验收 ✅ DONE
- [x] TRANSCRIPT 模式正常工作（与现有功能等价）
- [x] COMMAND 模式能根据指令修改文本
- [x] TRANSLATION 模式能正确翻译（doTranslatePostprocess + translate-settings store）
- [x] 上下文信息正确注入到 prompt
- [x] 超时/失败正确回退到 raw transcript（LLM timeout + catch fallback）

### T4 验收 ✅ DONE（核心功能）
- [x] 按 FN+C + 说指令 → CommandExecutor 生成 shell 命令并写入
- [x] 选中文本作为上下文传递给 CommandExecutor（capturedSelectedText）
- [x] 独立快捷键注册（FN+C）
- [x] FN 消歧修复 + 校验器修复 + resetToDefault 冲突解决
- [ ] Floating bar 正确显示 Command 模式状态（Phase 2）

### T5 验收 ✅ DONE
- [x] 按 FN+T + 说中文 → 正确输出英文（或目标语言）
- [x] 设置中可切换目标语言（translate-settings store + settings UI dropdown）
- [ ] 翻译结果自然、地道（依赖 LLM 质量，可通过切换模型优化）

### T6 验收 ✅ DONE
- [x] 在 Slack 中听写 → 语气随意（context injection 已实现）
- [x] 在邮件中听写 → 语气正式（context injection 已实现）
- [x] 在 Cursor 中听写 → 输出指令格式（context injection 已实现）
- [ ] 上下文信息正确存入数据库

### T2.5 验收
- [ ] 点在桌面空白处 → 录音 → 写入 → 返回 `success: false` 并给出提示
- [ ] 聚焦在文本输入框 → 写入 → 正常工作

### T9-T10 验收
- [x] T9: 录音时系统音量自动静音，结束后恢复 ✅
- [x] T10-a: 录音有音效反馈 ✅
- [x] T10-b: 全局快捷键粘贴上次转写 ✅（代码就绪，注释待启用）
