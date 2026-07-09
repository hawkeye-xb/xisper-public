# Xisper SwiftUI 现代化设计系统
> 基于 design-language-output 配色的完整设计方案

## 🎯 设计目标

**让 SwiftUI 不再丑陋，打造专业级 macOS 原生体验**

### 核心原则
1. **原生感优先** - 遵循 macOS Big Sur+ 的设计语言
2. **色彩科学** - 使用现有的 12 级色阶系统
3. **空间呼吸** - 大留白，让界面"breathe"
4. **微交互** - Spring 动画，悬停反馈，手势响应
5. **信息层次** - 清晰的视觉优先级

---

## 🎨 配色方案 (基于 DesignTokens.swift)

### 主色调 - Teal/Cyan (Primary)
```swift
主要操作: primary8  (#008F9F) - 录音按钮、CTA
悬停:     primary9  (#007C8B)
背景淡色: primary1  (#F8FCFD)
强调:     primary7  (#5AADB9)
```

**使用场景**:
- 录音按钮（大号圆形按钮）
- 主要操作按钮
- 选中状态
- 链接文字

### 中性色 - Gray (Neutral)
```swift
文字主要: neutral12 (#1E1F20) 
文字次要: neutral9  (#696D6D)
文字三级: neutral7  (#9C9FA0)
分割线:   neutral3  (#E9E9EA)
背景:     neutral1  (#FBFBFB)
卡片:     neutral2  (#F5F5F5) with shadow
```

### 语义色
```swift
成功/完成: success8  (#3E9245)
警告:      warning8  (#BE6000)
错误:      danger8   (#CB4E4A)
信息提示:  info8     (#008EA9)
```

---

## 📱 界面设计

### 1. 主界面 (录音控制) - HomeView

#### 布局结构
```
┌─────────────────────────────────────────┐
│                                         │
│           [Recording Status]            │  ← 状态文字 (xs)
│                                         │
│              ┌─────────┐                │
│              │         │                │
│              │   🎤    │                │  ← 大圆形按钮 (120pt)
│              │         │                │     Primary8 + Glow
│              └─────────┘                │
│                                         │
│           Hold FN to Record             │  ← 提示文字 (sm)
│                                         │
│   ┌─────────────────────────────────┐  │
│   │ 00:00:00                        │  │  ← 实时波形显示
│   │ ▁▃▅▇▅▃▁ ▁▃▅▇▅▃▁               │  │     音量可视化
│   └─────────────────────────────────┘  │
│                                         │
│   Last Transcription (3 min ago)       │  ← 最近记录预览
│   "The quick brown fox jumps..."       │     点击跳转详情
│                                         │
└─────────────────────────────────────────┘
```

#### 关键设计
1. **录音按钮**
   - 尺寸: 120pt × 120pt
   - 颜色: primary8 (正常) → primary9 (悬停) → primary10 (按下)
   - 效果: 
     ```swift
     .shadow(color: .primary8.opacity(0.3), radius: 20, y: 10)
     .scaleEffect(isPressed ? 0.95 : 1.0)
     .animation(.responsive, value: isPressed)
     ```
   - 录音时: 脉冲动画 + 红色边框

2. **波形可视化**
   - 高度: 80pt
   - 背景: neutral2
   - 波形: primary7 渐变到 primary8
   - 圆角: DesignRadius.lg (16pt)

3. **最近记录卡片**
   - 背景: neutral1
   - 边框: neutral3 (1pt)
   - 悬停: 淡入 shadow + neutral2 背景
   - 点击: Spring 动画过渡到详情页

---

### 2. 历史记录列表 - HistoryListView

#### 布局结构
```
┌─────────────────────────────────────────┐
│  History                    [🔍 Search] │  ← 导航栏
├─────────────────────────────────────────┤
│  Today                                   │  ← 日期分组 (neutral11, semibold)
│  ┌───────────────────────────────────┐  │
│  │ 14:32  12s  142 chars              │  │  ← 元数据行
│  │ The quick brown fox jumps over... │  │     (可展开/收起)
│  └───────────────────────────────────┘  │
│  ┌───────────────────────────────────┐  │
│  │ 13:45  8s   95 chars               │  │
│  │ Another transcription content...  │  │
│  └───────────────────────────────────┘  │
│                                         │
│  Yesterday                              │
│  ┌───────────────────────────────────┐  │
│  │ 18:20  15s  203 chars              │  │
│  │ Meeting notes about the new...    │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

#### 关键设计
1. **列表项卡片**
   ```swift
   // 正常状态
   .background(Color.neutral1)
   .overlay(RoundedRectangle(cornerRadius: DesignRadius.lg)
       .stroke(Color.neutral3, lineWidth: 1))
   
   // 悬停
   .background(Color.neutral2)
   .shadow(color: .neutral9.opacity(0.08), radius: 8, y: 4)
   ```

2. **日期分组标题**
   - 字体: DesignFont.sm, weight_semibold
   - 颜色: neutral11
   - 顶部间距: DesignSpacing.sm

3. **搜索框**
   - 宽度: 240pt
   - 高度: 32pt
   - 图标: magnifyingglass (SF Symbol)
   - 背景: neutral2
   - 焦点: primary8 边框

4. **滑动操作** (macOS trackpad 手势)
   - 左滑: 显示 [复制] [删除] 按钮
   - 删除: danger8 背景 + trash icon

---

### 3. 历史详情页 - HistoryDetailView

#### 布局结构
```
┌─────────────────────────────────────────┐
│  [← Back]              [Copy] [Delete]  │  ← 工具栏
├─────────────────────────────────────────┤
│  Today, March 13, 2026 at 14:32:15     │  ← 时间戳 (lg, neutral11)
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 📊 Metadata                     │   │  ← 折叠卡片
│  │                                 │   │
│  │ Duration:      12 seconds       │   │
│  │ Characters:    142              │   │
│  │ Words:         24               │   │
│  │ Speed:         710 CPM          │   │
│  │ Language:      English          │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 📝 Transcription                │   │  ← 主内容区
│  │                                 │   │
│  │ The quick brown fox jumps       │   │  可选中复制
│  │ over the lazy dog. This is a    │   │  可编辑（inline）
│  │ sample transcription showing... │   │
│  │                                 │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 🔧 Post-processing (Optional)   │   │  ← LLM 纠错结果
│  │                                 │   │  (如有)
│  │ [View Corrected Version]        │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

#### 关键设计
1. **工具栏按钮**
   ```swift
   // Secondary button style
   .font(.system(size: DesignFont.sm))
   .padding(.horizontal, DesignSpacing.button_padding_x)
   .padding(.vertical, 10)
   .background(Color.neutral2)
   .foregroundColor(.neutral11)
   .cornerRadius(DesignRadius.md)
   ```

2. **元数据卡片**
   - 背景: info1 (淡蓝色)
   - 图标: SF Symbols (chart.bar, text.alignleft, etc.)
   - 布局: 2 列 Grid
   - 动画: 点击折叠/展开 (gentle spring)

3. **内容区**
   - 字体: DesignFont.base (16pt)
   - 行高: lineHeight_base (1.5)
   - 可编辑: TextEditor with neutral2 background
   - 自动保存: 300ms debounce

4. **纠错对比视图** (可选)
   ```swift
   HStack(spacing: DesignSpacing.stack_gap) {
       VStack { /* 原文 */ }
       Divider()
       VStack { /* 纠错后 */ }
   }
   // Diff 高亮: danger3 (删除), success3 (新增)
   ```

---

### 4. 分析统计页 - AnalyticsView

#### 布局结构
```
┌─────────────────────────────────────────┐
│  Analytics         [Today ▼] [Week] ... │  ← 时间筛选
├─────────────────────────────────────────┤
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌──┐ │  ← 4 统计卡片
│  │ 2h 34m │ │ 45,678 │ │ 1h 12m │ │..│ │
│  │Speaking│ │ Chars  │ │ Saved  │ │  │ │
│  └────────┘ └────────┘ └────────┘ └──┘ │
│                                         │
│  ┌─────────────────────────────────┐   │  ← 趋势图表
│  │ Usage Trend                     │   │
│  │                                 │   │
│  │   📈 [Interactive Chart]        │   │  使用 Swift Charts
│  │                                 │   │  (iOS 16+)
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │  ← 词频分析
│  │ Top Keywords                    │   │
│  │                                 │   │
│  │  meeting █████████ 23          │   │  横向条形图
│  │  project ██████ 18              │   │
│  │  design ████ 12                 │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

#### 关键设计
1. **统计卡片**
   ```swift
   VStack(alignment: .leading, spacing: DesignSpacing.xxxs) {
       Image(systemName: "mic.fill")
           .foregroundColor(.primary8)
           .font(.system(size: 24))
       
       Text("2h 34m")
           .font(.system(size: DesignFont.xl2, weight: .semibold))
           .foregroundColor(.neutral12)
       
       Text("Speaking Time")
           .font(.system(size: DesignFont.sm))
           .foregroundColor(.neutral9)
   }
   .frame(maxWidth: .infinity, alignment: .leading)
   .padding(DesignSpacing.card_padding)
   .background(Color.neutral1)
   .cornerRadius(DesignRadius.xl)
   .shadow(color: .neutral9.opacity(0.06), radius: 12, y: 6)
   ```

2. **趋势图表** (Swift Charts)
   ```swift
   Chart(data) { item in
       LineMark(
           x: .value("Date", item.date),
           y: .value("Duration", item.duration)
       )
       .foregroundStyle(.primary8)
       .interpolationMethod(.catmullRom)
       
       AreaMark(
           x: .value("Date", item.date),
           y: .value("Duration", item.duration)
       )
       .foregroundStyle(
           LinearGradient(
               colors: [.primary8.opacity(0.3), .primary8.opacity(0.05)],
               startPoint: .top,
               endPoint: .bottom
           )
       )
   }
   .chartXAxis { /* 样式 */ }
   .chartYAxis { /* 样式 */ }
   ```

3. **时间筛选器**
   - Picker with SegmentedPickerStyle
   - 颜色: primary8 (选中)
   - 动画: .fast (0.13s)

---

### 5. 设置页 - SettingsView

#### 布局结构
```
┌─────────────────────────────────────────┐
│  Settings                               │
├─────────────────────────────────────────┤
│  ┌─────────────────────────────────┐   │
│  │ ⚙️ General                      │   │  ← 分组卡片
│  │                                 │   │
│  │ Theme          [System ▼]       │   │  Picker
│  │ Language       [English ▼]      │   │
│  │ Launch at Login   [Toggle On]   │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ ⌨️ Shortcuts                    │   │
│  │                                 │   │
│  │ Dictation      [FN] [Edit]      │   │  KeyRecorder
│  │ Translation    [⌥T] [Edit]      │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 🎤 Recording                     │   │
│  │                                 │   │
│  │ Input Device   [MacBook Pro...] │   │
│  │ Quality        High [▬▬▬▬▬▬▬▬]  │   │  Slider
│  │ Auto-stop      30s [▬▬▬──────]  │   │
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │ 👤 Account                       │   │
│  │                                 │   │
│  │ user@example.com                │   │
│  │                                 │   │
│  │ [Sign Out]                      │   │  Danger button
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

#### 关键设计
1. **设置项布局**
   ```swift
   HStack {
       VStack(alignment: .leading, spacing: 4) {
           Text("Theme")
               .font(.system(size: DesignFont.base, weight: .medium))
               .foregroundColor(.neutral12)
           
           Text("Choose your interface appearance")
               .font(.system(size: DesignFont.sm))
               .foregroundColor(.neutral9)
       }
       
       Spacer()
       
       Picker("", selection: $theme) { /* options */ }
           .pickerStyle(.menu)
           .frame(width: 120)
   }
   .padding(.vertical, DesignSpacing.xxs)
   ```

2. **Toggle 样式**
   ```swift
   Toggle("Launch at Login", isOn: $launchAtLogin)
       .toggleStyle(SwitchToggleStyle(tint: .primary8))
       .font(.system(size: DesignFont.base))
   ```

3. **快捷键录制器**
   - 点击 [Edit] 按钮
   - 弹出 Sheet: "Press your shortcut..."
   - 实时显示按键组合
   - 冲突检测: warning 颜色提示

4. **Slider 样式**
   ```swift
   Slider(value: $quality, in: 0...1)
       .accentColor(.primary8)
       .controlSize(.large)
   ```

5. **危险操作 (Sign Out)**
   ```swift
   Button("Sign Out") { /* action */ }
       .font(.system(size: DesignFont.base, weight: .medium))
       .foregroundColor(.danger8)
       .frame(maxWidth: .infinity)
       .padding(.vertical, DesignSpacing.button_padding_y)
       .background(Color.danger1)
       .cornerRadius(DesignRadius.md)
       .overlay(
           RoundedRectangle(cornerRadius: DesignRadius.md)
               .stroke(Color.danger3, lineWidth: 1)
       )
   ```

---

## 🧩 可复用组件库

### 1. XCard (通用卡片)
```swift
struct XCard<Content: View>: View {
    let content: Content
    var style: CardStyle = .default
    
    enum CardStyle {
        case default  // neutral1 + shadow
        case elevated // neutral1 + larger shadow
        case subtle   // neutral2 + no shadow
        case info     // info1 background
    }
    
    var body: some View {
        content
            .padding(DesignSpacing.card_padding)
            .background(backgroundColor)
            .cornerRadius(DesignRadius.xl)
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
    }
}
```

### 2. XButton (按钮)
```swift
struct XButton: View {
    let title: String
    let style: ButtonStyle
    let action: () -> Void
    
    enum ButtonStyle {
        case primary   // primary8 背景
        case secondary // neutral2 背景
        case danger    // danger8 背景
        case ghost     // 透明背景
    }
}
```

### 3. XStatCard (统计卡片)
```swift
struct XStatCard: View {
    let icon: String // SF Symbol
    let value: String
    let label: String
    let color: Color // primary8, success8, etc.
}
```

### 4. XTextField (输入框)
```swift
struct XTextField: View {
    @Binding var text: String
    let placeholder: String
    let icon: String?
    
    // 自动 focus ring (primary8)
    // 错误状态: danger8 border
}
```

### 5. XWaveformView (波形可视化)
```swift
struct XWaveformView: View {
    let levels: [CGFloat] // 0.0 - 1.0
    let color: Color = .primary7
    
    // 动画: 每个 bar 独立 spring 动画
}
```

---

## 🎭 动画规范

### 使用场景
```swift
// 1. 按钮点击
.scaleEffect(isPressed ? 0.96 : 1.0)
.animation(.responsive, value: isPressed)

// 2. 卡片悬停
.shadow(radius: isHovered ? 12 : 6)
.animation(.fast, value: isHovered)

// 3. 页面切换
.transition(.asymmetric(
    insertion: .move(edge: .trailing),
    removal: .move(edge: .leading)
))
.animation(.page, value: selectedPage)

// 4. 列表项删除
.transition(.asymmetric(
    insertion: .scale.combined(with: .opacity),
    removal: .move(edge: .leading).combined(with: .opacity)
))

// 5. 录音脉冲
.scaleEffect(isPulsing ? 1.1 : 1.0)
.opacity(isPulsing ? 0.7 : 1.0)
.animation(.bouncy.repeatForever(autoreverses: true), value: isPulsing)
```

---

## 📐 布局规范

### 窗口尺寸
```swift
// 主窗口 (录音界面)
.frame(width: 380, height: 520)

// 历史记录/分析/设置
.frame(minWidth: 600, idealWidth: 800, maxWidth: .infinity,
       minHeight: 500, idealHeight: 700, maxHeight: .infinity)
```

### 内边距系统
```swift
// 页面边距
.padding(DesignSpacing.page_margin) // 64pt

// 卡片内部
.padding(DesignSpacing.card_padding) // 40pt

// 组件间距
.spacing(DesignSpacing.stack_gap)    // 32pt

// 图标与文字
.spacing(DesignSpacing.icon_gap)     // 8pt
```

---

## 🌈 暗色模式适配

### 自动适配规则
```swift
// 所有颜色自动反转
Color.neutral1  →  Color.neutral12 (dark)
Color.neutral12 →  Color.neutral1  (dark)

// Primary 保持一致
Color.primary8 stays primary8 (both modes)

// 阴影调整
.shadow(color: .neutral9.opacity(0.08), ...)
// Dark: .shadow(color: .black.opacity(0.3), ...)
```

### 特殊处理
```swift
@Environment(\.colorScheme) var colorScheme

var cardBackground: Color {
    colorScheme == .dark ? Color.neutral11 : Color.neutral1
}
```

---

## 🚀 实现路线图

### Phase 1: 基础组件 (1 周)
- [x] XCard, XButton
- [ ] XTextField, XStatCard
- [ ] XWaveformView

### Phase 2: 核心页面 (2 周)
- [ ] HomeView (录音界面)
- [ ] HistoryListView
- [ ] HistoryDetailView

### Phase 3: 高级功能 (2 周)
- [ ] AnalyticsView + Swift Charts
- [ ] SettingsView
- [ ] 快捷键录制器

### Phase 4: 优化打磨 (1 周)
- [ ] 动画细节调整
- [ ] 暗色模式测试
- [ ] 性能优化

---

## 📦 文件结构

```
Xisper/
├── Views/
│   ├── Home/
│   │   ├── HomeView.swift
│   │   └── WaveformView.swift
│   ├── History/
│   │   ├── HistoryListView.swift
│   │   ├── HistoryDetailView.swift
│   │   └── HistoryCard.swift
│   ├── Analytics/
│   │   ├── AnalyticsView.swift
│   │   ├── StatCard.swift
│   │   └── TrendChart.swift
│   └── Settings/
│       ├── SettingsView.swift
│       └── ShortcutRecorder.swift
├── Components/
│   ├── XCard.swift
│   ├── XButton.swift
│   ├── XTextField.swift
│   └── XStatCard.swift
├── DesignSystem/
│   ├── DesignTokens.swift (已有)
│   └── XTheme.swift (新增)
└── Extensions/
    ├── Color+Semantic.swift
    └── View+Extensions.swift
```

---

**设计者**: AI Assistant  
**版本**: v2.0 - Complete SwiftUI System  
**日期**: 2026-03-13
