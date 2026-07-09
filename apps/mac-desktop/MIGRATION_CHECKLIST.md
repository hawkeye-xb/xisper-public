# Xisper macOS Native Migration Checklist

> 按模块拆分，每个功能点标注优先级（P0 核心 / P1 重要 / P2 边缘）和当前状态。
> 逐个开发、逐个验证、逐个勾选。

---

## 0. 核心流程（P0 — 必须先跑通）

整条链路：快捷键 → 录音 → ASR → 文字注入，任何一环断都无法使用。

### 0.1 OAuth 登录
- [ ] `xisper-mac://` 回调能正确触发 `AppDelegate.handleGetURL`
- [ ] PKCE code exchange 成功拿到 token
- [ ] Token 存入 Keychain 并可读取
- [ ] Token 自动刷新（过期前 5 分钟）
- [ ] 401 时自动 refresh 重试
- [ ] 页面可见性变化（sleep/wake）后重新检查 token
- [ ] 登出清理 Keychain + 状态重置
- [ ] 错误状态 UI（网络失败、服务端错误、用户取消）

### 0.2 权限检测
- [ ] Accessibility 权限检测正确（`AXIsProcessTrusted()`）
- [ ] Microphone 权限检测正确（`AVCaptureDevice.authorizationStatus`）
- [ ] 权限未授予时显示引导页，1s 轮询刷新
- [ ] "Open System Settings" 按钮跳转正确
- [ ] 权限授予后自动跳转到主界面
- [ ] 运行时权限被撤销 → 回到权限页（需要实现）

### 0.3 快捷键监听
- [ ] CGEventTap 创建成功（需 AX 权限）
- [ ] FN/Globe 键 press/release 正确捕获
- [ ] **`AppleFnUsageType` 修改**：启动时写 `0`（Do Nothing），退出时恢复原值 ← Electron 踩过的坑
- [ ] Press & Hold 模式：按下开始、松开停止
- [ ] Press to Toggle 模式：按一次开始、再按一次停止
- [ ] **快速按放竞态防护**：stop 等 start 完成后才执行 ← Electron 踩过的坑
- [ ] **系统休眠/唤醒后重建 CGEventTap** ← Electron 踩过的坑
- [ ] AX 权限失败 vs CGEventTap 创建失败的区分 ← Electron 踩过的坑

### 0.4 录音采集
- [ ] AVAudioEngine 正确启动 + installTap
- [ ] 输出格式：16kHz, Int16, mono PCM
- [ ] 音频数据回调正常（能打印 buffer 大小）
- [ ] 指定麦克风设备录音（非仅默认设备）
- [ ] 录音停止后正确释放资源

### 0.5 ASR WebSocket
- [ ] WebSocket 连接到 `wss://<backend>/api/v1/asr/proxy?token=<jwt>`
- [ ] `sendStart` 发送正确的 JSON config（含 language、featureToggles）
- [ ] `sendAudio` 发送 PCM binary frames
- [ ] `sendFinish` 发送结束信号
- [ ] 接收中间结果（partial text），更新 liveText
- [ ] 接收最终结果（final text）
- [ ] 8 秒超时兜底
- [ ] **连接超时设置**（`URLSessionConfiguration.timeoutIntervalForRequest`）← 当前缺失

### 0.6 文字注入
- [ ] 获取当前剪贴板内容（快照）
- [ ] 写入转写文本到剪贴板
- [ ] 模拟 Cmd+V 粘贴
- [ ] 异步恢复原剪贴板（120ms 延迟）
- [ ] **检测焦点元素是否可编辑再注入** ← Electron 踩过的坑，当前缺失
- [ ] **剪贴板恢复前检测是否被用户覆盖** ← Electron 踩过的坑

### 0.7 误触/静音检测
- [ ] < 200ms 视为误触，静默丢弃
- [ ] < 800ms 且 RMS < 100 视为静音，静默丢弃 ← Electron 踩过的坑
- [ ] 误触/静音不保存记录、不注入文字

### 0.8 End-to-End 验证
- [ ] 完整流程：FN 按下 → 说话 → FN 松开 → 文字出现在光标位置
- [ ] 气泡在录音期间可见
- [ ] 记录保存到 SwiftData
- [ ] 错误场景：无网络、ASR 超时、token 过期

---

## 1. 气泡/LiveTranscribe（P0）

### 1.1 NSPanel 行为
- [ ] 浮在所有窗口上方（包括全屏应用）
- [ ] 不获取焦点（`nonactivatingPanel`）
- [ ] 点击穿透（`ignoresMouseEvents = true`）
- [ ] 所有桌面空间可见（`fullScreenAuxiliary` collection behavior）
- [ ] 底部居中定位（当前屏幕）
- [ ] 显示/隐藏不影响主窗口
- [ ] 可拖动重定位（P2，当前未实现）

### 1.2 气泡内容
- [ ] 实时转写文本显示
- [ ] 录音中 → 显示气泡
- [ ] 后处理中 → 显示 loading 状态
- [ ] 完成/错误 → 隐藏气泡
- [ ] 文本自适应宽度（`min(屏幕宽 * 0.7, 700)`）
- [ ] 录音指示器（波形或红点）← 当前缺失

### 1.3 独立性
- [ ] 气泡和设置窗口完全独立：设置窗口开着不影响气泡
- [ ] 设置窗口关着不影响气泡
- [ ] 气泡不会因为主窗口操作而消失

---

## 2. 首页 Home（P1）

### 2.1 UI 元素
- [ ] 快捷键展示卡片 — **动态读取实际配置**，不硬编码 "FN" ← 当前硬编码
- [ ] "Configure" 链接跳转到设置
- [ ] 录音状态指示（idle/recording/finalizing/committing）
- [ ] 最近转写文本展示
- [ ] 错误消息展示

### 2.2 缺失功能
- [ ] 录音时长计时器显示（P2）
- [ ] 音频输入电平指示（P2）

---

## 3. 历史 History（P1）

### 3.1 列表
- [ ] 按日期分组（Today / Yesterday / 具体日期）← 当前无分组
- [ ] 每条记录：时间、内容预览（3行截断）、时长、录音模式
- [ ] 搜索过滤
- [ ] 复制文本（按钮，非仅右键菜单）
- [ ] 滑动删除 + 确认
- [ ] 清空全部 + 确认
- [ ] 空状态提示
- [ ] 记录变化时自动刷新

### 3.2 详情视图 ← 当前完全缺失
- [ ] 点击记录打开详情
- [ ] 显示完整原始文本（rawTranscribeContent）
- [ ] 显示后处理文本（transcribeContent）
- [ ] 显示元数据：创建时间、时长、录音模式、actionId
- [ ] 复制原始文本 / 后处理文本
- [ ] 音频文件 "Show in Finder"（如果有）
- [ ] 重新转写功能（读取音频文件重新 ASR）← P2

### 3.3 性能
- [ ] 分页加载或虚拟列表（`.fetchLimit`）← 当前全量加载
- [ ] 大量记录（1000+）不卡顿

---

## 4. 分析 Analytics（P1）

### 4.1 统计卡片
- [ ] 总说话时长
- [ ] 总字符数
- [ ] **节省时间**（字符数/60cpm - 说话时长）← 当前缺失，Electron 有
- [ ] **平均 WPM**（字符数/说话分钟数）← 当前缺失，Electron 有
- [ ] 会话总数 ← 当前有
- [ ] 今日会话数 ← 当前有
- [ ] **时间范围选择器**（Today / All Time）← 当前缺失，Electron 有

### 4.2 图表
- [ ] 近 7 天柱状图 — 当前有会话数
- [ ] **双轴图表**：字符数(左Y) + 时长(右Y) ← Electron 用 ECharts，Swift 可用 Charts 框架
- [ ] 图表空状态处理

---

## 5. 热词 Hotwords（P1）

### 5.1 CRUD
- [ ] 添加热词（输入框 + 回车提交）
- [ ] 删除单个热词
- [ ] 清空全部 + 确认
- [ ] 重复检测
- [ ] 长度验证（max 64）
- [ ] 空状态提示

### 5.2 导入导出 ← 当前完全缺失
- [ ] 导出 CSV
- [ ] 导入 CSV/TXT（带错误报告）

### 5.3 身份系统集成 ← 当前完全缺失
- [ ] 显示当前身份标识（badge）
- [ ] 身份关联的纠错词条数量展示
- [ ] LLM 后处理关闭时的提醒 banner

### 5.4 ASR 集成
- [ ] **热词 vocabularyId 传递给 ASR** ← 当前 TODO，从未实现

---

## 6. 身份选择器 Identity Selector（P1）← 已实现

### 6.1 UI
- [x] 侧边栏底部 account 行（email + tier + identity Menu）
- [x] 点击展开下拉列表
- [x] "None" 选项 + 所有可用身份
- [ ] 每个身份带图标 + 名称（当前仅文字）
- [x] 选中状态高亮

### 6.2 数据
- [x] `GET /api/v1/identities` 获取身份列表
- [x] `GET /api/v1/identities/:id` 获取身份详情（纠错规则、热词、vocabularyId）
- [x] 选中的身份 ID 持久化（UserDefaults）
- [x] 身份信息缓存本地

### 6.3 集成
- [x] LLM 后处理使用身份的纠错规则
- [x] ASR 使用身份的 vocabularyId
- [ ] Hotwords 页面展示当前身份信息

---

## 7. 用量展示 Quota/Usage（P1）← 当前完全缺失

### 7.1 侧边栏底部
- [ ] 显示用户邮箱
- [ ] 显示 Tier 标签（Free/Pro/Enterprise）
- [ ] 字符用量进度条 `used / limit`
- [ ] 颜色编码：<70% 正常、70-90% 警告、>90% 危险

### 7.2 数据
- [ ] `GET /auth/profile` 获取用户信息
- [ ] `GET /api/v1/rate-limit/status` 获取用量
- [ ] 5 分钟轮询刷新
- [ ] 录音结束后刷新
- [ ] 跨窗口共享（UserDefaults 替代 localStorage）

### 7.3 配额超限
- [ ] 录音前检查配额
- [ ] 超限时弹窗提示，阻止录音
- [ ] 区分字符超限 vs 时长超限

---

## 8. 设置 Settings（P1）

### 8.1 快捷键设置 ← 当前完全缺失
- [ ] 显示所有已注册的快捷键动作
- [ ] 每个动作：名称、描述、当前快捷键
- [ ] 点击进入捕获模式（CGEventTap CAPTURE mode）
- [ ] 实时显示按下的组合键
- [ ] 确认/取消按钮
- [ ] 冲突检测
- [ ] 重置为默认值
- [ ] 验证规则（最多3键、字母需配合修饰键等）

### 8.2 录音设置
- [ ] 录音模式选择（Press & Hold / Press to Toggle）← 已有
- [ ] **麦克风选择器**（列出所有输入设备）← 当前缺失
- [ ] 拦截 FN/Globe 键开关 ← 已有
- [ ] 静音系统音频开关 ← 已有
- [ ] 显示实时转写气泡开关 ← 已有
- [ ] 音效开关 ← 已有
- [ ] **语言选择器**（zh-CN / en-US / ja-JP）← 当前缺失，硬编码 zh-CN

### 8.3 AI & 后处理设置
- [ ] LLM 后处理开关 ← 已有
- [ ] **模式选择**（Clean / Rewrite）← 当前缺失
- [ ] **功能开关**：纠错、格式化、使用热词 ← 当前缺失
- [ ] **自定义 Prompt 模板** ← 已有但简化
- [ ] **恢复默认 Prompt 按钮** ← 当前缺失
- [ ] **翻译目标语言选择**（Auto/EN/ZH/JA）← 当前完全缺失

### 8.4 Webhook 设置
- [ ] Webhook 开关 ← 已有
- [ ] HTTP 方法选择 ← 已有
- [ ] URL 输入 ← 已有
- [ ] Body 模板编辑 ← 已有
- [ ] 测试连接按钮 ← 已有
- [ ] **超时配置** ← 当前缺失
- [ ] **重试次数配置** ← 当前缺失
- [ ] **自定义 Headers** ← 当前缺失

### 8.5 通用设置 ← 当前完全缺失
- [ ] 主题选择（Dark / Light / System）
- [ ] 界面语言（EN / ZH / JA）
- [ ] 开机自启动（Launch at Login）

### 8.6 账户
- [ ] 登出按钮 + 确认 ← 侧边栏有
- [ ] 显示当前账户邮箱 ← 侧边栏有

---

## 9. 数据层（P0/P1）

### 9.1 SwiftData 模型
- [ ] TranscribeRecord 字段完整（参照 Electron schema）← 已有
- [ ] `segmentsData` 实际填充 ← 当前从未填充
- [ ] `postprocessTimeMs` 实际记录 ← 当前从未设置
- [ ] `audioFilePath` 实际记录 ← 当前从未设置

### 9.2 音频文件存储 ← 当前完全缺失
- [ ] 录音 PCM 数据保存为 WAV 文件
- [ ] 路径：`{appSupport}/recordings/{YYYY-MM-DD}/{start}_{end}.wav`
- [ ] WAV 头写入（RIFF header, 16kHz, 16-bit, mono）
- [ ] 文件路径写入 TranscribeRecord.audioFilePath

### 9.3 热词共享存储
- [ ] `~/Library/Application Support/XisperHotwords/hotwords.json` ← 已有
- [ ] 与 Electron 版共享 ← 已有

### 9.4 配置持久化
- [ ] UserDefaults 各配置项 ← 已有
- [ ] Keychain token 存储 ← 已有

---

## 10. 系统集成（P1）

### 10.1 系统音频控制
- [ ] 录音时静音系统音频（CoreAudio kAudioDevicePropertyMute）← 已有
- [ ] 录音结束恢复音量 ← 已有
- [ ] **先 unmute 再播放结束音效** ← Electron 踩过的坑

### 10.2 音效
- [ ] 录音开始音效 ← 需要实现
- [ ] 录音结束音效 ← 需要实现
- [ ] 错误音效 ← 需要实现
- [ ] 尊重用户开关（`enableSoundEffects`）

### 10.3 Context 采集（LLM 后处理用）
- [ ] 获取当前焦点应用信息 ← ContextBridge 已有
- [ ] 获取窗口标题 ← 已有
- [ ] 获取选中文本 ← 已有
- [ ] 获取可见文本 ← 已有
- [ ] 获取浏览器 URL ← 已有
- [ ] 采集结果传递给 LLM prompt ← 需要接入

### 10.4 自动更新
- [ ] Sparkle 集成 ← 已有
- [ ] **替换 SUPublicEDKey 占位符** ← 当前是 PLACEHOLDER
- [ ] 菜单/Tray 手动检查更新 ← TrayView 已有

### 10.5 App 生命周期
- [ ] 关闭主窗口 = 隐藏（非退出）
- [ ] Tray 图标常驻
- [ ] Dock 行为（LSUIElement，需要时显示 Dock 图标）
- [ ] `app.quit()` 时清理资源（CGEventTap、AudioEngine、恢复 AppleFnUsageType）

---

## 11. 后处理流水线（P1）

### 11.1 LLM 后处理
- [ ] `POST /api/v1/llm/postprocess` 或 `/api/v1/llm/chat` 调用 ← 已有
- [ ] **LLM 返回空文本时回退到原始文本** ← 当前缺失
- [ ] 8 秒超时：先用原始文本，LLM 结果异步更新数据库 ← 需要实现
- [ ] 后处理上下文传递（app info、selected text、URL）← 需要接入
- [ ] 记录 `postprocessTimeMs`

### 11.2 ITN（反向文本规范化）
- [ ] 中文数字 → 阿拉伯数字 ← 已有
- [ ] 对原始 ASR 文本应用 ← 已有

### 11.3 翻译模式 ← 当前完全缺失
- [ ] `translate` hotkey action 触发翻译流程
- [ ] 翻译目标语言配置
- [ ] 翻译指令构建 + LLM 调用
- [ ] 翻译结果注入

### 11.4 Webhook
- [ ] 转写完成后触发 ← 已有
- [ ] 模板变量替换 ← 已有
- [ ] 3 次指数退避重试 ← 已有
- [ ] 失败时系统通知 ← 需要实现

---

## 12. 日志与调试（P2）

- [ ] 统一日志框架（`os.Logger` 或自定义）← 当前全是 `print()`
- [ ] 日志分级（debug/info/warn/error）
- [ ] 关键节点日志：快捷键触发、录音开始/停止、ASR 连接/结果、文字注入
- [ ] Keychain 操作错误日志 ← 当前静默
- [ ] 崩溃时的诊断信息

---

## 13. Electron 已知坑点在 Swift 中的对应处理

| # | 坑点 | Swift 状态 | 优先级 |
|---|------|-----------|--------|
| 1 | FN 键触发 Emoji Picker — 需改 `AppleFnUsageType` | 未实现 | P0 |
| 2 | 快捷键 start/stop 竞态 — 需串行化 | `@MainActor` 但无显式串行化 | P0 |
| 3 | 系统休眠后 CGEventTap 失效 — 需监听 wake 重建 | 未实现 | P0 |
| 4 | ASR 中途断连音频丢失 — 需 pending buffer | 未实现 | P1 |
| 5 | LLM 返回空文本 — 需回退到原始文本 | 未实现 | P1 |
| 6 | 无可编辑框时注入失败 — 需检测 AX 可编辑性 | 未实现 | P1 |
| 7 | 静音期间播放音效 — 需先 unmute | 未实现 | P1 |
| 8 | 误触/静音检测 — RMS 能量阈值 | 有 200ms 误触检测，无 RMS | P1 |
| 9 | AX 权限 vs CGEventTap 创建失败区分 | 未区分 | P1 |
| 10 | 运行时权限被撤销 → 回到权限页 | 未实现 | P1 |
| 11 | ContextBridge force-unwrap 可能崩溃 | 存在 `as!` | P1 |
| 12 | Hotwords 跨版本共享存储 | 已实现 ✅ | — |

---

## 14. 代码质量（持续改进）

- [ ] ASRClient 添加连接超时（`timeoutIntervalForRequest`）
- [ ] ContextBridge 中 `as!` 改为 `as?` 安全转换
- [ ] AuthManager Keychain 操作添加错误日志
- [ ] WebhookClient URL 验证（scheme + host）
- [ ] HotwordsStore 添加 `@MainActor`
- [ ] Sparkle 公钥替换 PLACEHOLDER

---

## 迁移顺序建议

```
Phase A（先跑通核心流程）:
  0.1 OAuth → 0.2 权限 → 0.3 快捷键 → 0.4 录音 → 0.5 ASR → 0.6 注入 → 0.7 误触检测 → 0.8 E2E 验证
  ↳ 同时修复 #13 表中所有 P0 坑点

Phase B（补全 P1 功能）:
  1. 气泡完善 → 7. 用量展示 → 6. 身份选择器 → 5. 热词集成
  8. 设置完善（快捷键自定义、麦克风、语言、后处理配置）
  3. 历史详情 → 4. 分析图表
  11. 后处理完善（翻译、上下文、超时机制）
  9. 数据层补全（音频文件、segments、postprocessTimeMs）

Phase C（P2 边缘功能 + 打磨）:
  10. 系统集成（音效、自动更新密钥、通用设置）
  12. 日志框架
  14. 代码质量
  UI 细节：拖动气泡位置、历史导出、图表增强
```
