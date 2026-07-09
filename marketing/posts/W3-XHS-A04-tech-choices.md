# A-04 | 小红书 | W3 周二

**标题**：独立开发选 Electron 是不是错误？我的真实体验

**关键词**：Electron、独立开发、技术选型、Mac App、前端开发

---

## 正文

"你怎么用 Electron 做 Mac App？Swift 不好吗？"

我估计会被问这个问题一百遍，所以专门写一篇。

先说背景：我做了一个 macOS 语音输入工具 Xisper，前端用的 Electron + Vue 3。对，2026 年了我还在用 Electron。

为什么？

**1/ 我是客户端开发，Electron 是我最熟的方案**

Vibe Coding 的前提是你得能判断 AI 写出来的代码好不好。用不熟的技术栈就失去了这个判断力。

> 📸 **[图 1]**
> **需要准备**：Xisper 的 package.json 或 monorepo 结构截图。展示 Electron + Vue3 + TypeScript 的技术栈。不需要完整内容，截关键部分就好。

**2/ Xisper 的核心不在 UI 性能**

Xisper 不是一个复杂 UI 的 App。它大部分时间是一个菜单栏图标 + 一个弹窗。核心是音频采集、WebSocket 通信、系统级快捷键、剪贴板操作。这些 Electron 都能做。

**3/ 需要原生能力的地方，用原生**

Fn 键监听——用 Rust 写了一个 napi-rs 原生模块。文字粘贴——用 robotjs 模拟键盘。后续计划用 Swift 写 dylib 做更多系统级交互。

Electron 负责 UI 和胶水层，重活交给原生。

> 📸 **[图 2]**
> **需要准备**：fn-key-monitor 的 Rust 代码截图（packages/fn-key-monitor 里的核心文件）。展示"Electron App 里也有 Rust 原生模块"，打破"Electron = 纯 JS"的印象。截一小段关键代码就好。

**踩过的坑？有。**

- 全屏模式下浮窗显示：Electron 的 setVisibleOnAllWorkspaces 在 macOS 上有各种边界情况
- Dock 图标管理：LSUIElement app 的 dock.show/hide 行为不直觉
- 包体积：是比 Swift 大，但用户能接受

**后悔吗？不后悔。**

技术选型没有绝对的对错，只有适不适合你的上下文。我一个人做，Electron 让我用最熟悉的技术最快出活，这就够了。

> 📸 **[图 3]**
> **需要准备**：Xisper 最终产品的界面截图——干净、好用。证明"Electron 也能做出质感不错的产品"。

你用什么技术栈做独立开发？评论区聊聊。

---

**标签**：#Electron #独立开发 #技术选型 #MacApp #前端 #VibeCoding
