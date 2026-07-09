# 准确的多语言缺失报告

## 关键发现

你的疑问是对的！但答案很有趣：

**大部分看起来"硬编码"的英文字符串，实际上已经被 Xcode 自动提取并翻译了！**

### Xcode String Catalog 自动本地化机制

Xcode 15+ 的 `.xcstrings` 格式会自动提取这些字符串：

1. **自动提取的条件：**
   - SwiftUI 的 `Text("string")` 
   - 某些特定的 SwiftUI 视图初始化器

2. **为什么显示中文？**
   - 即使代码写的是 `Text("Weekly Overview")`
   - Xcode 编译时自动识别这个字符串
   - 在 `Localizable.xcstrings` 中自动创建条目
   - 运行时根据系统语言显示对应翻译

3. **证据：**
   ```swift
   // HotwordsView.swift 第286行 - 看起来是硬编码
   Text("Your Hotwords")
   
   // 但在 Localizable.xcstrings 第2483行已经有翻译：
   "Your Hotwords": {
     "zh-Hans": {
       "value": "您的热词"  // ← 这就是中文用户看到的！
     }
   }
   ```

---

## ✅ 已自动本地化（看起来硬编码但实际已翻译）

这些字符串**无需修改**，Xcode 已经自动处理：

| 字符串 | 中文翻译 | 位置 |
|--------|---------|------|
| "Weekly Overview" | "每周概览" | AnalyticsView.swift:132 |
| "Character Tokens" | "字符令牌" | ContentView.swift:513 |
| "Voice-first input, reimagined." | "语音优先输入，全新演绎。" | HomeView.swift:24 |
| "You can change the hotkey in Settings." | "你可以在设置中更改快捷键。" | HomeView.swift:49 |
| "Your Hotwords" | "您的热词" | HotwordsView.swift:286 |
| "Add" | "添加" | HotwordsView.swift:218 |
| "Clear All" | "清除全部" | HotwordsView.swift:253 |
| "Mode" | "模式" | HistoryView.swift:548 |
| "Audio" | "音频" | HistoryView.swift:563 |
| "Today" | "今天" | HistoryView.swift:55 |
| "Dictation" | "听写" | HistoryView.swift:297 |
| "Translate" | "翻译" | HistoryView.swift:295 |
| "Ready" | "就绪" | TrayView.swift:85 |
| "Finalizing…" | "处理中…" | TrayView.swift:91, HomeView.swift:116 |
| "Processing…" | "处理中…" | TrayView.swift:96, HomeView.swift:121 |
| "Recording…" | "录音中…" | TrayView.swift:87 |
| "Unlimited" | "无限" | ContentView.swift:557 |
| "No usage limits" | "无使用限制" | ContentView.swift:560 |
| "Show in Finder" | "在 Finder 中显示" | HistoryView.swift:695 |
| "ASR service error — tap retry to re-transcribe" | "ASR服务错误 — 点击重试以重新转录" | HistoryView.swift:413 |
| "None" | "无" | ContentView.swift:364 |

---

## ❌ 真正缺失的字符串（需要添加）

这些字符串**确实缺失**，需要添加到 Localizable.xcstrings：

### 1. AnalyticsView.swift

#### Line 137-138: Chart Legend Labels
```swift
ChartLegendDot(color: Color.primary8, label: "Speaking Time")
ChartLegendDot(color: Color.warning8, label: "Characters")
```
**问题：** `ChartLegendDot` 是自定义组件，它的 `label` 参数类型是 `String` 而不是 `LocalizedStringKey`，所以 Xcode 不会自动提取。

**解决方案：**
```swift
ChartLegendDot(color: Color.primary8, label: NSLocalizedString("Speaking Time", comment: "Chart legend"))
ChartLegendDot(color: Color.warning8, label: NSLocalizedString("Characters", comment: "Chart legend"))
```

---

### 2. HotwordsView.swift

#### Line 237, 244: Menu Label Items
```swift
Label("Import", systemImage: "square.and.arrow.down")
Label("Export", systemImage: "square.and.arrow.up")
```
**问题：** 在 `Menu` 的 `Button` 内部使用 `Label`，Xcode 的自动提取可能失效。

**解决方案：**
```swift
Label(NSLocalizedString("Import", comment: ""), systemImage: "square.and.arrow.down")
Label(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up")
```

#### Line 406, 416: Error Messages
```swift
errorMessage = "Failed to read file"
errorMessage = "Invalid CSV file"
```
**问题：** 普通字符串赋值，不会自动本地化。

**解决方案：**
```swift
errorMessage = NSLocalizedString("Failed to read file", comment: "")
errorMessage = NSLocalizedString("Invalid CSV file", comment: "")
```

#### Line 163: Success Message
```swift
showSuccess("Exported successfully")
```
**解决方案：**
```swift
showSuccess(NSLocalizedString("Exported successfully", comment: ""))
```

#### Line 433-439: Import Result Messages
```swift
showSuccess(r.skipped > 0
    ? "Imported \(r.added) hotwords, skipped \(r.skipped) duplicates"
    : "Imported \(r.added) hotwords")
    
showSuccess("All hotwords already exist, skipped \(r.skipped)")
```
**解决方案：** 使用 `String(format:)` 和本地化字符串
```swift
if r.added > 0 {
    if r.skipped > 0 {
        showSuccess(String(format: NSLocalizedString("Imported %d hotwords, skipped %d duplicates", comment: ""), r.added, r.skipped))
    } else {
        showSuccess(String(format: NSLocalizedString("Imported %d hotwords", comment: ""), r.added))
    }
} else if r.skipped > 0 {
    showSuccess(String(format: NSLocalizedString("All hotwords already exist, skipped %d", comment: ""), r.skipped))
}
```

#### Line 501: Validation Error
```swift
errorMessage = "'\(word)' too long (max \(HotwordItem.maxCharacters) characters)"
```
**解决方案：**
```swift
errorMessage = String(format: NSLocalizedString("'%@' too long (max %d characters)", comment: ""), word, HotwordItem.maxCharacters)
```

#### Line 510: Add Success Messages
```swift
showSuccess(addedCount == 1 ? "Added 1 hotword" : "Added \(addedCount) hotwords")
```
**解决方案：** 使用复数规则
```swift
showSuccess(String(format: NSLocalizedString("Added %d hotword(s)", comment: "Plural handled in stringsdict"), addedCount))
```

#### Line 514: All Invalid Error
```swift
errorMessage = "All words already exist or invalid"
```
**解决方案：**
```swift
errorMessage = NSLocalizedString("All words already exist or invalid", comment: "")
```

#### Line 539, 541: Clear Results
```swift
showSuccess("Cleared \(result.deleted) hotwords")
errorMessage = result.errorMessage ?? "Failed to clear hotwords"
```
**解决方案：**
```swift
showSuccess(String(format: NSLocalizedString("Cleared %d hotwords", comment: ""), result.deleted))
errorMessage = result.errorMessage ?? NSLocalizedString("Failed to clear hotwords", comment: "")
```

---

### 3. HistoryView.swift

#### Line 57: Yesterday Label
```swift
label = "Yesterday"
```
**问题：** 虽然在条件语句中，但 Xcode 有时无法正确提取。

**解决方案：**
```swift
label = NSLocalizedString("Yesterday", comment: "")
```

#### Line 290: Character Count
```swift
"\(rawCharsCount) chars"
```
**解决方案：**
```swift
String(format: NSLocalizedString("%d chars", comment: ""), rawCharsCount)
```

#### Line 297: ASK Mode Label
```swift
case "ask": "ASK"
```
**解决方案：**
```swift
case "ask": NSLocalizedString("ASK", comment: "Mode label")
```

#### Line 356: Tooltip
```swift
.help("Retry transcription")
```
**解决方案：**
```swift
.help(NSLocalizedString("Retry transcription", comment: ""))
```

#### Line 418: No Content Placeholder
```swift
Text(record.transcribeContent.isEmpty ? "(No content)" : record.transcribeContent)
```
**解决方案：**
```swift
Text(record.transcribeContent.isEmpty ? NSLocalizedString("(No content)", comment: "") : record.transcribeContent)
```

#### Line 540-542: Metadata Labels
```swift
MetadataItem(label: "Duration", value: durationLabel)
MetadataItem(label: "Raw Chars", value: "\(rawCharsCount)")
MetadataItem(label: "Speed", value: "\(cpmLabel) CPM")
```
**问题：** `MetadataItem` 的 `label` 参数是 `String` 类型。

**解决方案：**
```swift
MetadataItem(label: NSLocalizedString("Duration", comment: ""), value: durationLabel)
MetadataItem(label: NSLocalizedString("Raw Chars", comment: ""), value: "\(rawCharsCount)")
MetadataItem(label: NSLocalizedString("Speed", comment: ""), value: "\(cpmLabel) CPM")
```

#### Line 670: Retranscribing Status
```swift
Text(isRetranscribing ? "Retranscribing..." : "Retry Transcription")
```
**解决方案：**
```swift
Text(isRetranscribing ? NSLocalizedString("Retranscribing...", comment: "") : NSLocalizedString("Retry Transcription", comment: ""))
```

#### Line 761: Copy Button States
```swift
Text(copied ? "Copied" : "Copy")
```
**解决方案：**
```swift
Text(copied ? NSLocalizedString("Copied", comment: "") : NSLocalizedString("Copy", comment: ""))
```

---

### 4. ContentView.swift

#### Line 332: Identity Default Label
```swift
Text(identity.activeLabel ?? "Identity")
```
**解决方案：**
```swift
Text(identity.activeLabel ?? NSLocalizedString("Identity", comment: ""))
```

#### Line 479: Account Default Label
```swift
Text(auth.userEmail ?? "Account")
```
**解决方案：**
```swift
Text(auth.userEmail ?? NSLocalizedString("Account", comment: ""))
```

---

### 5. 日期格式问题（特殊）

#### HistoryView.swift Line 518: Detail Sheet Date Title

**当前问题：**
```swift
private var dateLabel: String {
    let f = DateFormatter()
    f.dateStyle = .long    // ← 导致显示 "2026年4月8日 14:08:30"
    f.timeStyle = .medium
    return f.string(from: record.createdAt)
}
```

**用户需求：** 使用固定格式 "2026-04-08 14:08:30"，不随语言变化

**解决方案：**
```swift
private var dateLabel: String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"  // ISO 8601-like format
    return f.string(from: record.createdAt)
}
```

---

## 统计总结

| 类别 | 数量 |
|------|------|
| ✅ 已自动本地化（无需修改） | 20 |
| ❌ 需要添加本地化 | 22 |
| 🔧 需要修改日期格式 | 1 |
| **总计需要修改的位置** | **23** |

---

## 修复优先级

### 高优先级（用户可见的界面文本）
1. ✅ AnalyticsView: "Speaking Time", "Characters" 图例
2. ✅ HotwordsView: "Import", "Export" 菜单
3. ✅ HistoryView: "Duration", "Speed", "Raw Chars" 元数据标签
4. ✅ HistoryView: "Copy", "Copied" 按钮
5. ✅ HistoryView: 日期格式修复
6. ✅ ContentView: "Identity", "Account" 默认标签

### 中优先级（错误和状态消息）
1. ✅ HotwordsView: 所有错误和成功消息
2. ✅ HistoryView: "ASK" 模式标签
3. ✅ HistoryView: "(No content)" 占位符
4. ✅ HistoryView: "Retry transcription" 提示

### 低优先级（辅助文本）
1. HistoryView: "chars" 字符计数
2. HistoryView: "Yesterday" 分组标签（Today 已有）

---

## 下一步行动

1. 修改上述 23 处代码，添加 `NSLocalizedString()` 调用
2. 在 `Localizable.xcstrings` 中添加这 22 个新键的英文和中文翻译
3. 修复日期格式使用固定 ISO 格式
4. 测试所有语言环境确保正确显示
5. 清理之前创建的 `MISSING_I18N.md`（因为它基于错误的假设）
