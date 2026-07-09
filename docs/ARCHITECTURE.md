# Xisper 项目架构总览

> 基于 map.md、decisions.md、git 提交历史整理。用于理解整体架构、模块职责、已知坑点，以及 Electron vs 原生开发的对比。

---

## 1. 整体架构图

见 `docs/architecture-diagram.svg`（或 `docs/architecture-diagram.excalidraw` 可编辑）。

---

## 2. 模块划分与实现方式

### 2.1 客户端层（Client）

| 模块 | 技术栈 | 实现方式 | 状态 |
|-----|--------|----------|------|
| **Electron Desktop** | Electron 33 + Vue3 (Web) | 主窗口 + LiveTranscribe 气泡窗口，均加载 **Web 打包产物**（`file://` 或 dev 时 `localhost:7005`） | ✅ 主力生产 |
| **Web (Browser)** | Vue3 + Vite | 独立 SPA，可单独访问 `demo/xisper/` 路由 | ✅ 生产 |
| **mac-desktop (Native)** | SwiftUI + Swift | 纯原生 UI，无 WebView | 开发中，核心流程未打通 |

**关键：Electron 与 Web 的关系**

- Electron 不嵌入 Web 开发服务器，而是**构建时**把 `apps/web` 的 `dist` 复制到 `apps/desktop/dist/web`。生产环境加载 `file://.../web/index.html`。
- 两个窗口共享 `partition: 'persist:xisper'`，localStorage 一致（auth_token、config、theme 等）。
- Web 路由：Hash 模式（Electron 兼容 `file://`），History 模式（Web 独立部署）。

### 2.2 服务端层（Server）

| 模块 | 技术栈 | 职责 | 部署 |
|-----|--------|------|------|
| **services** | Hono + Cloudflare Workers | API 网关、鉴权、ASR 代理、LLM 代理、应用更新、身份/纠错包 | Beta 8787 / Prod |
| **ai-worker** | Hono + Cloudflare Workers | LLM 后处理、Chat 对话；内部 AI Gateway（Groq/Gemini/DeepSeek） | Beta 8788 / Prod |

**API 入口概览**

- `POST /api/v1/auth/verify` — JWT 验证
- `WS /api/v1/asr/proxy` — ASR 实时转写 WebSocket
- `POST /api/v1/llm/postprocess` — 转写后 LLM 纠错（服务端转发到 ai-worker）
- `POST /api/v1/llm/chat` — Chat 对话（同上）
- `GET /api/v1/identities`、`/identities/:id` — 身份/纠错包
- `GET /api/app/updates/feed/:channel` — Electron 自动更新
- `GET /api/v1/app/mac/updates/feed/:channel` — 原生 Mac 应用 Sparkle 更新

### 2.3 运营/管理

| 模块 | 技术栈 | 职责 |
|-----|--------|------|
| **admin** | Vue3 + Pages | 用户管理、发布管理、Prompt 编辑、今日活跃 |
| **landing** | Vue3 + Pages | 官网、SEO、Alpha 横幅 |

---

## 3. 数据流与调用关系

```
用户按键 (FN/Globe)
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  Client: Electron 主进程 / mac-desktop Swift                      │
│  • 快捷键监听 (CGEventTap / koffi+robotjs)                         │
│  • 录音控制、气泡窗口显示                                          │
└────────────────────────────┬────────────────────────────────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │                        │                        │
    ▼                        ▼                        ▼
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ Electron     │    │ Web (Renderer)   │    │ mac-desktop       │
│ Main Process │    │ Vue3 + IPC       │    │ SwiftUI 原生      │
│              │    │                  │    │                   │
│ • 窗口管理   │    │ • 录音 UI         │    │ • RecordingCoord  │
│ • 快捷键     │    │ • 历史/分析/设置  │    │ • ASRClient       │
│ • 数据库 IPC │    │ • API 调用        │    │ • InputWriter     │
└──────┬───────┘    └────────┬─────────┘    └────────┬──────────┘
       │                     │                        │
       │  loadURL(file://web) │  Bearer Token          │
       └─────────────────────┼────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  services (Cloudflare Worker)                                     │
│  • JWT 鉴权  • ASR WebSocket 代理  • LLM 代理  • 身份/纠错包      │
└────────────────────────────┬────────────────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
┌─────────────────┐  ┌─────────────┐  ┌─────────────────┐
│ Alibaba Fun-ASR │  │ ai-worker   │  │ Logto / D1 / KV │
│ (WebSocket)     │  │ (LLM)       │  │ R2 / APP_UPDATE  │
└─────────────────┘  └─────────────┘  └─────────────────┘
```

---

## 4. UI 设计与交互

### 4.1 Web 设计系统

- 路径：`apps/web/src/styles/`（tokens、themes、element-theme）
- 原则：Less is More、Apple HIG + Linear + Arc 风格
- 主题：light / dark / system，存 localStorage
- 组件：Element Plus 深度定制 + Tailwind

### 4.2 主要页面

| 路由 | 组件 | 说明 |
|-----|------|------|
| `/` | Home | 录音入口、快捷键展示、最近转写 |
| `/history` | History | 转写历史（lazy load，注意 v-loading 坑） |
| `/analytics` | Analytics | 使用统计 |
| `/hotwords` | Hotwords | 热词 + 身份/专业领域选择（Dialog） |
| `/settings` | Settings | 快捷键、后处理、Webhook 等 |
| `/live-transcribe` | LiveTranscribeView | 独立气泡窗口，无 MainLayout |
| `/auth` | AuthSetup | Logto OAuth 登录 |
| `/permissions` | PermissionsSetup | 麦克风 + 辅助功能权限 |

### 4.3 已废弃/移除功能

- **Smart Scenario Switching**：依赖 Apple Events 权限，已移除
- **Scenarios 营销页**：改为 Industry Expertise（纠错包）
- **v-loading 指令**：macOS 16 + Electron 33 下会触发 NSRangeException，改用 `{loading ? <spinner/> : <content/>}`

---

## 5. 已知坑点与注意事项（来自 decisions.md + commits）

### 5.1 Electron 相关

- **会话分区**：主窗口和 LiveTranscribe 必须用 `partition: 'persist:xisper'`，否则 localStorage 不一致
- **FN/Globe 键**：macOS 13+ 需 `defaults write -g AppleFnUsageType -int 0`，CGEventTap 无法单独拦截 Globe
- **热词存储**：Beta/Prod 的 userData 路径不同，热词会丢失。已改为 `~/Library/Application Support/XisperHotwords/hotwords.json` 统一存储
- **Dock 行为**：LSUIElement 下只在 main window show 时 `app.dock.show()`，不 hide，保证 Cmd+Tab 可见
- **Tray About 弹窗**：必须传 parent window，否则 macOS 主进程阻塞
- **全屏隔离**：气泡用 `type:'panel'` + `setAlwaysOnTop` + `skipTransformProcessType`，主窗口 `setVisibleOnAllWorkspaces(false)` 避免盖住全屏

### 5.2 服务端

- **ASR 代理**：close 回调必须同步，`sessionResolve` 放第一行，quota 用 fire-and-forget + 5s 超时
- **ASR 代理**：buffer 500 帧，超时 log 溢出
- **健康检查**：需要 DEEPSEEK_API_KEY，否则 config 为 degraded

### 5.3 Web 端

- **History 卡顿**：`getAllRecords()` 在主进程排序大数组会阻塞 IPC；`v-loading` 在 macOS 16 会崩溃
- **Router 守卫**：`ensureValidToken` 若 refresh 挂住，`next()` 不执行，导航卡死

### 5.4 原生 mac-desktop

- **OAuth**：`xisper-mac://` 仅 dev 后端支持，prod 需 `xisper://`
- **辅助功能权限**：信任与**完整路径**绑定，需固定 build 路径（如 `dev.sh`）

---

## 6. Electron vs 原生开发对比

| 维度 | Electron | mac-desktop (Swift) |
|-----|----------|---------------------|
| **UI** | 嵌入 Web 打包产物，Vue3 | 纯 SwiftUI |
| **性能** | Chromium 进程，内存占用高 | 原生，更轻 |
| **快捷键** | koffi + robotjs / CGEventTap | CGEventTap |

**原生优势**：更轻、启动快、更省内存、系统集成更好。

**Electron 优势**：Web 与桌面共用一套 UI 代码，迭代快；已有完整功能。

---

## 7. 环境与部署

| 环境 | API | Admin | Landing |
|-----|-----|-------|---------|
| Beta | xisper-dev.hawkeye-xb.com | xisper-admin-beta | xisper-landing |
| Prod | xisper.hawkeye-xb.com | xisper-admin | xisper-landing |

- 根路径 `/` 在 beta/prod 会 302 到 landing
- Electron 更新：`/api/app/updates/feed/{beta|production}`
- 原生 Mac 更新：`/api/v1/app/mac/updates/feed/{beta|production}`

---

## 8. 相关文档

- `.agent_memory/map.md` — 模块路径、端口、绑定
- `.agent_memory/decisions.md` — 决策与坑点
- `apps/mac-desktop/AGENT_HANDOFF.md` — 原生 Mac 开发交接
- `docs/typeless-shortcut-implementation-desensitized.md` — Typeless 快捷键竞品分析
- `docs/feature-parity-plan.md` — 功能对等计划（含已移除项）
