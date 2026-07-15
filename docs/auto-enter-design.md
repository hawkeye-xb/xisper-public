# Auto-Enter After Paste — 设计文档

> RD: 耳机按键触发粘贴后自动回车  
> 版本: 0.10.10  
> 日期: 2026-07-15

---

## 1. 背景与动机

耳机按键触发语音输入后，文字贴到输入框，用户还要伸手按 Enter 才能发送，破坏了免手体验。本功能在耳机按键触发的录音结束后，自动模拟按下 Enter 键。

### 设计约束

| 约束 | 说明 |
|------|------|
| 仅耳机触发 | FN 快捷键触发不自动回车（手在键盘上） |
| 默认关闭 | Settings 可开关，避免非聊天场景误触 |
| 不阻塞 MainActor | `commitResult()` 不能被 Enter 等待卡住 |

---

## 2. 技术方案

### 2.1 触发源追踪 — `TriggerSource`

```swift
enum TriggerSource {
    case fn         // FN 快捷键
    case headphone  // 耳机 Play/Pause 按键
}
```

`RecordingCoordinator.triggerSource` 在 `onHeadphoneTrigger()` 中设为 `.headphone`，在所有中止/提交路径的 `currentActionId = nil` 处同步重置为 `.fn`（共 7 处）。

### 2.2 粘贴 + 回车 — `writeAndPressEnter()`

```swift
@MainActor
static func writeAndPressEnter(_ text: String) async -> WriteResult {
    let result = await write(text)   // 复用现有粘贴逻辑
    guard result.success else { return result }

    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
        simulateEnter()  // CGEvent keyCode 36 (Return)
    }
    return result
}
```

**关键决策**：Enter 通过 `DispatchQueue.global().asyncAfter(300ms)` 异步派发，不阻塞 MainActor。`write()` 调用 `simulatePaste()` 后立即返回，300ms 的延迟足够任何 app 完成粘贴。

### 2.3 入口判断 — `commitResult()`

```swift
let useAutoEnter = triggerSource == .headphone && ConfigStore.shared.autoEnterAfterPaste
let result = useAutoEnter
    ? await InputWriter.writeAndPressEnter(finalText)
    : await InputWriter.write(finalText)
```

---

## 3. 方案迭代

| 版本 | 方案 | 问题 |
|------|------|------|
| 尝试 1 | AXObserver 监听 `kAXValueChangedNotification` | 用户选择简化，未实施 |
| 尝试 2 | MainActor 轮询 AXValue (50ms, 1s timeout) | **阻塞 MainActor**，commitResult 被卡 1s，下一轮按键排队 |
| 最终 | `DispatchQueue.global().asyncAfter(300ms)` | 不等待粘贴结果，异步派发 Enter |

为何放弃轮询：`commitResult()` 是 `@MainActor async`，轮询中的 `Task.sleep` 虽挂起但不释放 MainActor 给下一次 `onHeadphoneTrigger()` 的 `DispatchQueue.main.async`，导致第二轮按键被延迟到超时后才执行。

---

## 4. 边界条件覆盖

| # | 场景 | 行为 |
|---|------|------|
| 1 | 耳机开始 → 耳机结束 | ✅ 正常粘贴 + 300ms 后回车 |
| 2 | 耳机开始 → 自动停止（静音 3min） | ✅ 同上 |
| 3 | FN 触发 | ✅ 仅粘贴，不回车 |
| 4 | Auto-Enter 关闭 | ✅ 仅粘贴 |
| 5 | 空内容录音 | ✅ 不粘贴，不回车 |
| 6 | ESC 放弃 | ✅ `commitResult` 不被调用 |
| 7 | 误触 (<200ms) | ✅ 走 mistouch 分支，不提交 |
| 8 | 蓝牙断连 | ✅ abort 路径，`triggerSource` 已重置 |
| 9 | 连续两轮耳机 | ✅ 每轮独立，状态机序列化 |

---

## 5. 改动文件

| 文件 | 改动 |
|------|------|
| `Managers/ConfigStore.swift` | `autoEnterAfterPaste: Bool`，UserDefaults 持久化，`autoEnterBinding` |
| `Services/RecordingCoordinator.swift` | `TriggerSource` 枚举，`triggerSource` 属性 + 7 处重置，`commitResult()` 分支 |
| `Services/InputWriter.swift` | `writeAndPressEnter()` + `simulateEnter()` |
| `Services/HotkeySystem.swift` | `onHeadphoneTrigger()` 调用 `setTriggerSource(.headphone)` |
| `Views/Settings/SettingsView.swift` | "Auto-Enter After Paste" toggle |
| `Localizable.xcstrings` | 中英文 i18n 字符串 |

---

## 6. 已知限制

- **非聊天 app**（Terminal / VS Code 等）：Enter 行为不同（执行命令 / 换行），建议在此类场景关闭 Toggle
- **300ms 固定延迟**：未使用 AXObserver 事件驱动，极端慢 app 可能需要更长时间
- **粘贴后快速切换 App**：Enter 可能打到新 App，暂无焦点保护
