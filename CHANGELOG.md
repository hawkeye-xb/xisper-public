# Changelog

All notable changes to Xisper. Format based on [Keep a Changelog](https://keepachangelog.com/).

Sections: `Added` · `Changed` · `Deprecated` · `Fixed` · `Security`.
Component tags: `[macOS]` `[ai-worker]` `[services]` `[landing]`.

---

## [Unreleased]

### Changed
- **[ai-worker]** 替代已下线的 Groq 模型: `qwen3-32b → qwen3.6-27b` (中文/CJK)、`llama-3.3-70b → gpt-oss-120b` (英文)。解决 Groq 7/17 + 8/16 两个下线节点。
- **[ai-worker]** 海外路由分流正式生效:中文→qwen3.6-27b、英文→gpt-oss-120b (之前接口断连,中英全打第一个槽)。

### Added
- **[ai-worker]** 服务端 PostHog 埋点 `xisper_ai_postprocess`:记录实际命中模型、fallback 深度、延迟、请求语言/渠道,用途为远程验证模型迁移正确性。

---

## [0.10.10] — 2026-07-15

### Added
- **[macOS]** 耳机按键粘贴后自动回车 (Auto-Enter After Paste)。仅耳机按键触发、默认关闭、Settings 可开关。粘贴完成后 300ms 异步发送 Enter (keyCode 36),不阻塞 MainActor。
- **[macOS]** `TriggerSource` 枚举 (fn/headphone) 追踪录音触发源,`commitResult()` 据此决定是否 auto-enter。

### Fixed
- **[macOS]** 中止路径 (蓝牙断连/设备变更/ASR 错误等 7 处) 未重置 `triggerSource`,导致下次 FN 按键录音错误触发 auto-enter。

---

## [0.10.7] — 2026-07-15

### Fixed
- **[macOS]** 录音提示音被系统静音吃掉: `muteSystem()` 延迟 150ms 执行,确保 NSSound "Tink" 播完再静音输出设备。

---

## [0.10.6] — 2026-07-15

### Added
- **[macOS]** ESC 键中断录音:录音/后处理/提交中任意非 idle 状态按 ESC 即可放弃本次录音,不写数据库、不注入文字、不触发 webhook。

---

## [0.10.5] — 2026-07-11

### Fixed
- **[macOS]** 登录修复:增加 `prompt=consent`,确保 Logto 下发 refresh_token —— 根除每 55 分钟退出登录 (0.10.4 之前的版本).
- **[macOS]** token 刷新错误分类:仅 `invalid_grant` (HTTP 400/401/403) 才清 token 登出; 5xx/429/URLError 按瞬态处理并重试 (0.10.4).

---

## [0.10.0] — 2026-07-10

### Added
- **[macOS]** PostHog 客户端产品埋点 (`xisper_app_*`),含启动漏斗、核心循环、配额命中、身份切换、崩溃采集.
- **[macOS]** 原生崩溃捕捉 (PLCashReporter via posthog-ios SDK,dSYM 自动符号化).

### Fixed
- **[macOS]** 系统音频静音/恢复幂等性:防止多次调用导致静音状态丢失 (#24).
- **[macOS]** SPM Bundle 冲突:beta 渠道不再全局覆写 `PRODUCT_NAME`,避免启动崩溃 (SPM 资源包文件名冲突).

---

## [0.9.3] — 2026-07

### Fixed
- **[macOS]** 键盘 phantom key 清理:锁屏/安全输入导致 `keyUp` 吞掉后,FN 快捷键直到下次重启都不触发 —— 现通过硬件状态调和 (HID state table) 自动清除滞留按键并恢复热键.

---

## [0.9.0] — 2026-06

### Added
- **[macOS]** FN 键语音输入核心功能.
- **[macOS]** 媒体键触发 (Play/Pause) 录制.
- **[ai-worker]** AI 后端 (postprocess / metering / quota) 首版.
- **[services]** 认证 + ASR WebSocket 代理 + 计费 + 授权.
- **[landing]** 营销官网 (Vue 3 SSG,CF Pages 部署).

---

For detailed commit-level changes: `git log apps/<component>/ --oneline`.
