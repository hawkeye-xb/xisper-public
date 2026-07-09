# Xisper SwiftUI 组件库参考手册

> 基于 DesignTokens.swift 的完整组件实现指南

---

## 📦 组件总览

本组件库提供**开箱即用的 SwiftUI 组件**，遵循 Xisper 设计语言，让 SwiftUI 开发既美观又高效。

### 核心组件 (8 个)
1. **XCard** - 通用卡片容器
2. **XButton** - 按钮 (4 种样式)
3. **XTextField** - 输入框 (带图标、焦点状态)
4. **XStatCard** - 统计数据卡片
5. **XWaveform** - 音频波形可视化
6. **XToggle** - 开关 (自定义配色)
7. **XPicker** - 下拉选择器
8. **XKeyRecorder** - 快捷键录制器

---

## 🎨 设计原则

1. **使用 DesignTokens.swift** - 所有颜色、间距、圆角直接引用 tokens
2. **深色模式自适应** - 通过 `@Environment(\.colorScheme)` 自动切换
3. **macOS 原生感** - 使用 SF Symbols、系统字体、标准动画
4. **可复用性** - 通过 `@ViewBuilder` 和泛型实现灵活组合

---

## 📚 组件详细文档

### 1. XCard - 通用卡片

**功能**: 提供一致的卡片样式，支持多种预设风格。

```swift
struct XCard<Content: View>: View {
    let content: Content
    let style: CardStyle
    
    enum CardStyle {
        case `default`  // neutral2 + 淡阴影
        case elevated   // neutral2 + 大阴影
        case subtle     // neutral3 + 无阴影
        case info       // info1 背景
        case success    // success1 背景
    }
    
    init(
        style: CardStyle = .default,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(DesignSpacing.card_padding)
            .background(backgroundColor)
            .cornerRadius(DesignRadius.xl)
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                y: shadowY
            )
    }
    
    private var backgroundColor: Color {
        switch style {
        case .default, .elevated:
            return .neutral2
        case .subtle:
            return .neutral3
        case .info:
            return .info1
        case .success:
            return .success1
        }
    }
    
    private var shadowColor: Color {
        style == .subtle ? .clear : .neutral9.opacity(0.08)
    }
    
    private var shadowRadius: CGFloat {
        switch style {
        case .default: return 8
        case .elevated: return 16
        default: return 0
        }
    }
    
    private var shadowY: CGFloat {
        switch style {
        case .default: return 4
        case .elevated: return 8
        default: return 0
        }
    }
}

// 使用示例
XCard(style: .elevated) {
    VStack(alignment: .leading, spacing: 8) {
        Text("Card Title")
            .font(.system(size: DesignFont.lg, weight: .semibold))
        Text("Card content goes here")
            .font(.system(size: DesignFont.base))
            .foregroundColor(.neutral9)
    }
}
```

---

### 2. XButton - 按钮组件

**功能**: 4 种预设风格的按钮，支持图标。

```swift
struct XButton: View {
    let title: String
    let icon: String? // SF Symbol name
    let style: ButtonStyle
    let action: () -> Void
    
    @State private var isPressed = false
    
    enum ButtonStyle {
        case primary   // primary8 背景, 白色文字
        case secondary // neutral2 背景, neutral12 文字
        case danger    // danger8 背景, 白色文字
        case ghost     // 透明背景, primary8 文字
    }
    
    var body: some View {
        Button(action: {
            withAnimation(.fast) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.fast) {
                    isPressed = false
                }
                action()
            }
        }) {
            HStack(spacing: DesignSpacing.icon_gap) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: DesignFont.sm))
                }
                Text(title)
                    .font(.system(size: DesignFont.base, weight: .medium))
            }
            .padding(.horizontal, DesignSpacing.button_padding_x)
            .padding(.vertical, DesignSpacing.button_padding_y)
            .background(backgroundColor)
            .foregroundColor(foregroundColor)
            .cornerRadius(DesignRadius.md)
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(.plain)
    }
    
    private var backgroundColor: Color {
        switch style {
        case .primary: return .primary8
        case .secondary: return .neutral2
        case .danger: return .danger8
        case .ghost: return .clear
        }
    }
    
    private var foregroundColor: Color {
        switch style {
        case .primary, .danger: return .white
        case .secondary: return .neutral12
        case .ghost: return .primary8
        }
    }
}

// 使用示例
XButton(
    title: "Save Changes",
    icon: "checkmark.circle.fill",
    style: .primary
) {
    print("Saved!")
}
```

---

### 3. XTextField - 输入框

**功能**: 带图标、焦点高亮的输入框。

```swift
struct XTextField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String? // SF Symbol
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: DesignSpacing.icon_gap) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: DesignFont.base))
                    .foregroundColor(isFocused ? .primary8 : .neutral7)
            }
            
            TextField(placeholder, text: $text)
                .font(.system(size: DesignFont.base))
                .textFieldStyle(.plain)
                .focused($isFocused)
        }
        .padding(DesignSpacing.input_padding_x)
        .background(Color.neutral2)
        .cornerRadius(DesignRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.md)
                .stroke(
                    isFocused ? Color.primary8 : Color.clear,
                    lineWidth: 2
                )
        )
        .animation(.fast, value: isFocused)
    }
}

// 使用示例
@State private var searchText = ""

XTextField(
    text: $searchText,
    placeholder: "Search...",
    icon: "magnifyingglass"
)
```

---

### 4. XStatCard - 统计卡片

**功能**: 显示单个统计数据，带图标和标签。

```swift
struct XStatCard: View {
    let icon: String // SF Symbol
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)
            
            Text(value)
                .font(.system(size: DesignFont.xl2, weight: .semibold))
                .foregroundColor(.neutral12)
            
            Text(label)
                .font(.system(size: DesignFont.sm, weight: .medium))
                .foregroundColor(.neutral9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignSpacing.card_padding)
        .background(Color.neutral1)
        .cornerRadius(DesignRadius.xl)
        .shadow(color: .neutral9.opacity(0.06), radius: 12, y: 6)
    }
}

// 使用示例
XStatCard(
    icon: "mic.fill",
    value: "2h 34m",
    label: "Speaking Time",
    color: .primary8
)
```

---

### 5. XWaveform - 波形可视化

**功能**: 实时音量可视化（录音时）。

```swift
struct XWaveform: View {
    let levels: [CGFloat] // 0.0 - 1.0
    let color: Color
    let barCount: Int
    
    init(
        levels: [CGFloat],
        color: Color = .primary7,
        barCount: Int = 40
    ) {
        self.levels = levels
        self.color = color
        self.barCount = barCount
    }
    
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(
                            width: (geo.size.width - CGFloat(barCount - 1) * 2) / CGFloat(barCount),
                            height: barHeight(for: index, maxHeight: geo.size.height)
                        )
                        .animation(.responsive.delay(Double(index) * 0.01), value: levels)
                }
            }
        }
    }
    
    private func barHeight(for index: Int, maxHeight: CGFloat) -> CGFloat {
        let level = levels[safe: index] ?? 0.0
        return max(4, level * maxHeight) // 最小高度 4pt
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// 使用示例
@State private var audioLevels: [CGFloat] = Array(repeating: 0.2, count: 40)

XWaveform(levels: audioLevels, color: .primary8)
    .frame(height: 60)
```

---

### 6. XToggle - 自定义开关

**功能**: 使用 primary8 颜色的 Toggle。

```swift
struct XToggle: View {
    @Binding var isOn: Bool
    let label: String
    
    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(SwitchToggleStyle(tint: .primary8))
            .font(.system(size: DesignFont.base, weight: .medium))
            .foregroundColor(.neutral12)
    }
}

// 使用示例
@State private var launchAtLogin = true

XToggle(isOn: $launchAtLogin, label: "Launch at Login")
```

---

### 7. XPicker - 下拉选择器

**功能**: 自定义样式的 Picker。

```swift
struct XPicker<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let options: [T]
    let label: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: DesignFont.base, weight: .medium))
                .foregroundColor(.neutral12)
            
            Spacer()
            
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.description).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }
    }
}

// 使用示例
enum Theme: String, CaseIterable, CustomStringConvertible {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var description: String { rawValue }
}

@State private var selectedTheme: Theme = .system

XPicker(
    selection: $selectedTheme,
    options: Theme.allCases,
    label: "Theme"
)
```

---

### 8. XKeyRecorder - 快捷键录制器

**功能**: 录制快捷键组合。

```swift
struct XKeyRecorder: View {
    @Binding var shortcut: String
    @State private var isRecording = false
    
    var body: some View {
        Button(action: {
            isRecording = true
        }) {
            HStack(spacing: 4) {
                if isRecording {
                    Text("Press keys...")
                        .foregroundColor(.neutral9)
                } else {
                    ForEach(shortcut.components(separatedBy: " + "), id: \.self) { key in
                        Text(key)
                            .font(.system(size: DesignFont.sm, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.neutral3)
                            .cornerRadius(DesignRadius.xs)
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(DesignSpacing.input_padding_y)
            .frame(minWidth: 80)
            .background(Color.neutral2)
            .cornerRadius(DesignRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.md)
                    .stroke(isRecording ? Color.primary8 : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onKeyPress { keyPress in
            if isRecording {
                // Handle key press recording
                shortcut = keyPress.characters
                isRecording = false
                return .handled
            }
            return .ignored
        }
    }
}

// 使用示例
@State private var dictationShortcut = "FN"

XKeyRecorder(shortcut: $dictationShortcut)
```

---

## 🎨 配色使用指南

### 文字颜色
```swift
// 主要文字 (标题、正文)
.foregroundColor(.neutral12)

// 次要文字 (描述、元数据)
.foregroundColor(.neutral9)

// 三级文字 (提示、占位符)
.foregroundColor(.neutral7)

// 禁用状态
.foregroundColor(.neutral6)
```

### 背景颜色
```swift
// 画布背景
.background(Color.neutral1)

// 卡片背景
.background(Color.neutral2)

// 悬停/选中
.background(Color.neutral3)

// 强调背景
.background(Color.primary1)  // 淡蓝色
.background(Color.success1)   // 淡绿色
.background(Color.danger1)    // 淡红色
```

### 边框颜色
```swift
// 默认边框
.stroke(Color.neutral3, lineWidth: 1)

// 分割线
Divider().background(Color.neutral3)

// 焦点边框
.stroke(Color.primary8, lineWidth: 2)
```

---

## 🎭 动画使用

### 预设动画 (来自 DesignTokens.swift)
```swift
// 微动画 (按钮点击)
.animation(.micro, value: isPressed)  // 0.08s

// 快速 (悬停状态)
.animation(.fast, value: isHovered)   // 0.13s

// 标准 (UI 反馈)
.animation(.normal, value: isActive)  // 0.21s

// Spring 动画
.animation(.responsive, value: scale) // 弹性动画
.animation(.bouncy, value: offset)    // 弹跳动画
```

### 常用动画模式
```swift
// 1. 按钮缩放
.scaleEffect(isPressed ? 0.96 : 1.0)
.animation(.responsive, value: isPressed)

// 2. 渐入渐出
.opacity(isVisible ? 1.0 : 0.0)
.animation(.normal, value: isVisible)

// 3. 滑动进入
.offset(x: isVisible ? 0 : -20)
.animation(.default, value: isVisible)

// 4. 旋转
.rotationEffect(.degrees(isLoading ? 360 : 0))
.animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isLoading)
```

---

## 📐 布局规范

### 常用间距
```swift
VStack(spacing: DesignSpacing.xxxs)  // 8pt  - 紧密
VStack(spacing: DesignSpacing.xxs)   // 16pt - 标准
VStack(spacing: DesignSpacing.xs)    // 20pt - 舒适
VStack(spacing: DesignSpacing.sm)    // 24pt - 组间距
VStack(spacing: DesignSpacing.md)    // 32pt - 大间距
```

### 内边距
```swift
.padding(DesignSpacing.xxxs)        // 8pt  - 小组件
.padding(DesignSpacing.xxs)         // 16pt - 按钮
.padding(DesignSpacing.sm)          // 24pt - 卡片
.padding(DesignSpacing.card_padding) // 40pt - 大卡片
```

### 窗口尺寸建议
```swift
// 录音主窗口
.frame(width: 380, height: 520)

// 历史/设置窗口
.frame(
    minWidth: 600,
    idealWidth: 800,
    maxWidth: .infinity,
    minHeight: 500,
    idealHeight: 700,
    maxHeight: .infinity
)
```

---

## 🚀 使用示例

### 完整页面示例: HomeView

```swift
struct HomeView: View {
    @State private var isRecording = false
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 40)
    @State private var elapsedTime: TimeInterval = 0
    
    var body: some View {
        VStack(spacing: DesignSpacing.sm) {
            // 状态文字
            Text(isRecording ? "Recording..." : "Ready to Record")
                .font(.system(size: DesignFont.xs, weight: .medium))
                .foregroundColor(.neutral9)
            
            Spacer().frame(height: 20)
            
            // 录音按钮
            Button(action: toggleRecording) {
                ZStack {
                    Circle()
                        .fill(Color.primary8)
                        .frame(width: 120, height: 120)
                        .shadow(color: .primary8.opacity(0.3), radius: 20, y: 10)
                        .scaleEffect(isRecording ? 1.1 : 1.0)
                        .animation(.bouncy.repeatForever(autoreverses: true), value: isRecording)
                    
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 12)
            
            // 提示文字
            Text("Hold FN to Record")
                .font(.system(size: DesignFont.sm))
                .foregroundColor(.neutral7)
            
            Spacer().frame(height: 24)
            
            // 波形卡片
            XCard(style: .default) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(formatTime(elapsedTime))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.neutral12)
                    
                    XWaveform(levels: audioLevels, color: .primary7)
                        .frame(height: 60)
                }
            }
            .frame(height: 80)
            
            Spacer().frame(height: 16)
            
            // 最近记录
            XCard(style: .subtle) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Transcription (3 min ago)")
                        .font(.system(size: DesignFont.xs, weight: .medium))
                        .foregroundColor(.neutral7)
                    
                    Text("The quick brown fox jumps over the lazy dog...")
                        .font(.system(size: DesignFont.base))
                        .foregroundColor(.neutral12)
                        .lineLimit(2)
                }
            }
        }
        .padding(DesignSpacing.xl)
        .frame(width: 380, height: 520)
        .background(Color.neutral1)
    }
    
    private func toggleRecording() {
        withAnimation(.responsive) {
            isRecording.toggle()
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
```

---

## 📖 更多资源

- **完整设计文件**: `design/xisper-swiftui-complete.pen`
- **设计系统文档**: `design/SWIFTUI-DESIGN-SYSTEM.md`
- **配色 Token**: `design-language-output/DesignTokens.swift`

---

**文档版本**: v1.0  
**最后更新**: 2026-03-13  
**维护者**: AI Assistant
