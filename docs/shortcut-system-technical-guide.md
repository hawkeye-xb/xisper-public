# Xisper 快捷键系统技术实现文档

> 本文档详细描述 Xisper 快捷键系统的完整技术实现，包括：按键监听机制、允许/禁止的按键规则、按下/抬起行为、FN 键特殊处理、快捷键录制模式等所有细节。

---

## 目录

1. [系统架构概览](#1-系统架构概览)
2. [双层拦截架构](#2-双层拦截架构)
3. [可监听的按键分类](#3-可监听的按键分类)
4. [禁止/受限按键](#4-禁止受限按键)
5. [按键行为详解](#5-按键行为详解)
6. [FN 键的特殊机制](#6-fn-键的特殊机制)
7. [快捷键录制（Capture）模式](#7-快捷键录制capture模式)
8. [快捷键字符串格式与规范化](#8-快捷键字符串格式与规范化)
9. [快捷键匹配状态机](#9-快捷键匹配状态机)
10. [时序参数](#10-时序参数)
11. [跨平台差异](#11-跨平台差异)

---

## 1. 系统架构概览

Xisper 的快捷键系统由三个核心模块协作完成：

```
用户按键
    │
    ▼
┌─────────────────────────────────────────┐
│  CGEventTap (Rust, kCGHIDEventTap)      │  ← 第一层：HID 硬件事件层
│  fn-key-monitor native module           │    macOS 专属，最早拦截
│  • FN 键 press/release                  │    Globe Emoji 抑制
│  • FN+key 组合黑名单消费                 │    拦截已配置的快捷键组合
│  • 修饰键+主键组合黑名单消费              │
└──────────────────┬──────────────────────┘
                   │ 未被消费的事件继续传递
                   ▼
┌─────────────────────────────────────────┐
│  uiohook-napi (JS, session level)       │  ← 第二层：会话级键盘钩子
│  UiohookSource                          │    跨平台，报告 keydown/keyup
│  • 所有未被 HID 层消费的按键              │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  ShortcutMatcher (TypeScript)           │  ← 状态机层
│  • 修饰键状态追踪                         │    纯软件匹配，无 I/O
│  • FN 歧义消除（无定时器方案）             │
│  • 防抖 + 最小按压时长                    │
└──────────────────┬──────────────────────┘
                   │
                   ▼
         onShortcutDown / onShortcutUp
              （录音开始 / 录音停止）
```

---

## 2. 双层拦截架构

### 2.1 第一层：CGEventTap（macOS HID 层）

- **位置**：`packages/fn-key-monitor/src/platform/macos.rs`
- **类型**：`kCGHIDEventTap`（最早的拦截点，早于所有应用层）
- **注册方式**：`CGEventTapCreate` with `kCGHeadInsertEventTap`
- **只拦截以下三类事件**（白名单设计，不干扰其他按键）：

  | 拦截类型 | 触发条件 | 处理方式 |
  |---------|---------|---------|
  | **FN 键本身** | `event_type == kCGEventFlagsChanged && FN_KEY_MASK` | 消费（吞掉），向 JS 层发送 press/release 通知 |
  | **FN+key 组合** | FN 被按住 && keycode 在 `interceptKeyCodesWhenFnDown` 白名单中 | 消费（吞掉），用户配置哪些键需要被拦截 |
  | **修饰键+主键组合** | `current_modifiers == required_modifiers && keycode == required_keycode`（精确匹配） | 消费（吞掉），只消费完全匹配的组合 |

- **修饰键掩码常量**：

  ```
  SHIFT_MASK   = 0x20000
  CONTROL_MASK = 0x40000
  ALT_MASK     = 0x80000   (Option)
  COMMAND_MASK = 0x100000
  FN_KEY_MASK  = 0x800000
  ```

- **精确匹配原则**：拦截快捷键时使用 `==`（等号），而非 `&`（与运算），确保只在修饰键状态完全符合时才消费事件。例如配置了 `Cmd+Shift+T`，则按 `Ctrl+Cmd+Shift+T` 不会被拦截。

### 2.2 第二层：uiohook-napi（会话级钩子）

- **位置**：`apps/desktop/src/main/hotkey/input/uiohook-source.ts`
- **平台**：跨平台（macOS/Windows/Linux）
- **事件**：`keydown`、`keyup`，携带 uiohook keycode
- **注意**：如果某个按键被 HID 层消费，uiohook 就**看不到**该事件

### 2.3 Globe Emoji 抑制

FN/Globe 键在 macOS 上默认会弹出 Emoji 选择器。Xisper 通过调用 HIToolbox 私有 API 禁用此行为：

- **API**：`TISUpdateFnUsageType`（通过 `dlopen`/`dlsym` 动态加载）
- **框架路径**：`Carbon.framework/Versions/A/Frameworks/HIToolbox.framework`
- **操作**：将 `AppleFnUsageType` 设置为 `0`（"Do Nothing"）
- **还原**：应用退出时恢复原始值
- **Bounce 机制**：若当前值已等于目标值，先短暂设置成其他值，再改回目标值，强制触发 TIS 通知，确保系统实时生效

---

## 3. 可监听的按键分类

### 3.1 FN/Globe 键（独立使用）

| 快捷键字符串 | 描述 | 备注 |
|------------|------|------|
| `FN` | Globe/FN 键单独按下 | **默认录音快捷键** |

- **独立使用**：按下 FN → 开始录音；松开 FN → 停止录音
- 这是唯一通过 CGEventTap 而非 uiohook 监听的按键

### 3.2 右侧修饰键（可独立使用）

右侧修饰键**允许**作为独立快捷键使用（无需搭配其他键）：

| 快捷键字符串 | 别名 | uiohook keycode |
|------------|------|----------------|
| `RightShift` | `ShiftRight` | 54 |
| `RightControl` | `RightCtrl`, `ControlRight`, `CtrlRight` | 3613 |
| `RightAlt` | `RightOption`, `AltRight`, `OptionRight` | 3640 |
| `RightMeta` | `RightCmd`, `RightCommand`, `MetaRight`, `CmdRight`, `CommandRight` | 3676 |

**允许右侧修饰键独立使用的理由**：左侧修饰键是系统级组合键前缀（如 `Shift`、`Ctrl`、`Cmd`），若允许独立使用会干扰所有包含该修饰键的操作；而右侧修饰键在日常操作中较少单独使用，副作用可控。

### 3.3 FN + 修饰键组合

FN 键可与右侧修饰键组合使用：

| 示例 | 说明 |
|------|------|
| `FN+LeftShift` | FN 作为修饰，LeftShift 作为主键 |
| `FN+RightControl` | FN 作为修饰，RightControl 作为主键 |

> **注意**：`FN+RightShift` 等形式在 validator 中通过（有 2 个修饰键且包含 FN），但 normalizer 会返回空字符串（因为两者都被视为 modifier，mainKeys 为空）。这是已知的边界行为。

### 3.4 修饰键 + 主键组合

任意修饰键（含 FN）都可与以下主键组合：

#### 字母键 A-Z（必须搭配修饰键）

| 示例 | 描述 |
|------|------|
| `Cmd+T` 或 `LeftMeta+T` | 左 Command + T |
| `FN+T` | FN/Globe + T |
| `RightAlt+E` | 右 Option + E |

所有 26 个字母键（A-Z）单独使用时被禁止，**必须搭配至少一个修饰键**。

#### 数字键 0-9（必须搭配修饰键）

| 示例 | 描述 |
|------|------|
| `Cmd+1` | Command + 1 |
| `FN+3` | FN + 3 |

所有数字键单独使用时被禁止，**必须搭配至少一个修饰键**。

#### 符号键（可独立使用，也可组合）

以下符号键**允许单独使用**：

| 按键 | 快捷键字符串 |
|------|------------|
| `[` | `[` |
| `]` | `]` |
| `;` | `;` |
| `'` | `'` |
| `.` | `.` |
| `/` | `/` |
| `,` | `,` |

以下符号键/变体**必须搭配修饰键**：

| 按键 | 快捷键字符串别名 |
|------|--------------|
| `` ` `` / `~` | `Backtick`, `Backquote`, `Grave`, `Tilde` |

#### 导航键（可独立使用）

| 按键 | 快捷键字符串 |
|------|------------|
| ↑ | `Up` / `ArrowUp` |
| ↓ | `Down` / `ArrowDown` |
| ← | `Left` / `ArrowLeft` |
| → | `Right` / `ArrowRight` |
| Page Up | `PageUp` / `Page_Up` |
| Page Down | `PageDown` / `Page_Down` |
| Home | `Home` |
| End | `End` |

#### Delete 键（可独立使用）

| 按键 | 快捷键字符串 |
|------|------------|
| Delete（Forward Delete） | `Delete` |

### 3.5 组合键数量上限

- 最多支持 **3 个主键**组合（`MAX_KEY_COMBINATION_COUNT = 3`）
- 修饰键数量不限（但实用性有限）
- **禁止字母+数字直接组合**（如 `A+1`），必须通过修饰键搭配

---

## 4. 禁止/受限按键

### 4.1 完全禁止的按键（任何情况下不可用）

| 类别 | 按键 |
|------|------|
| **功能键** | F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12 |
| **系统特殊键** | Backspace, Escape, Tab, Enter/Return |

> F13/F14/F15 在 uiohook keycode 表中存在，但不在禁止列表中，理论上可以通过组合键使用。

### 4.2 单独使用时禁止（必须搭配修饰键）

| 类别 | 按键 |
|------|------|
| **字母键** | A-Z（26 个） |
| **数字键** | 0-9（10 个） |
| **反引号/波浪线** | `` ` ``, `~` |

### 4.3 左侧修饰键（不可单独使用）

| 按键 | 快捷键字符串 |
|------|------------|
| 左 Shift | `LeftShift` / `ShiftLeft` / `Shift` |
| 左 Control | `LeftControl` / `LeftCtrl` / `ControlLeft` / `Ctrl` / `Control` |
| 左 Alt/Option | `LeftAlt` / `LeftOption` / `AltLeft` / `Alt` / `Option` |
| 左 Command/Meta | `LeftMeta` / `LeftCmd` / `LeftCommand` / `Meta` / `Cmd` / `Command` |

**禁止原因**：左侧修饰键是全局热键的前缀键，若允许单独触发，会导致所有包含该修饰键的正常操作（如 `Cmd+C` 复制）在松开修饰键时误触发快捷键。

---

## 5. 按键行为详解

### 5.1 正常录音模式（Push-to-Talk，默认模式）

```
按下快捷键 ──► onShortcutDown ──► 开始录音
                                     │
                                     │  用户持续说话...
                                     │
松开快捷键 ──► onShortcutUp ──► 停止录音 + 插入文字
```

#### 按下（Keydown）行为

1. `CGEventTap` 检测到匹配的组合 → **消费事件**（系统和其他应用看不到）
2. uiohook 收到 `keydown` 事件（如果未被 HID 层消费）
3. `ShortcutMatcher.handleKeyDown(keycode)` 执行匹配逻辑
4. 匹配成功 → `commitDown(shortcut)`
5. `commitDown` 检查防抖：若距上次按下 < `50ms` → 忽略
6. 记录 `activeShortcut` 和 `lastDownTime`
7. 调用 `events.onShortcutDown(shortcut)` → 录音开始

#### 松开（Keyup）行为

1. uiohook 收到 `keyup` 事件
2. `ShortcutMatcher.handleKeyUp(keycode)` 执行
3. 若匹配 `activeShortcut` → `commitUp(shortcut)`
4. `commitUp` 检查最小按压时长：若按压时长 < `32ms` → 延迟到满足时长后再执行
5. `executeUp(shortcut)` → 调用 `events.onShortcutUp(shortcut)` → 录音停止 + 文字插入

### 5.2 Hands-Free（无需双手/拨动）模式

通过按下 `FN+Space` 进入/退出：

```
按下 FN+Space ──► 进入 Hands-Free 模式（开始录音）
                    │
                    │  用户无需持续按键，自由说话...
                    │
再次按下快捷键 ──► 退出 Hands-Free 模式（停止录音 + 插入文字）
```

- **进入方式**：FN+Space（固定，不可更改）
- **退出方式**：再次按下当前快捷键（或再次按下 FN+Space）
- **状态持久**：Hands-Free 模式下松开按键不会停止录音

### 5.3 翻译模式

通过 `FN+Shift` 激活：

```
按下 FN+Shift ──► 进入翻译录音模式
松开 FN+Shift ──► 停止录音 + 翻译后插入文字
```

---

## 6. FN 键的特殊机制

### 6.1 FN 键的双重身份

FN 键有两种使用方式：

| 使用方式 | 快捷键字符串 | 说明 |
|---------|------------|------|
| **纯 FN**（单独使用） | `FN` | 只按 FN，不按其他键 |
| **FN 作修饰键**（组合使用） | `FN+T`, `FN+Space` 等 | FN 按住期间按下其他键 |

### 6.2 无定时器歧义消除策略

当用户按下 FN 键时，系统无法立即判断用户意图是"纯 FN"还是"FN+某键"。Xisper 采用**无定时器**的确定性策略：

```
FN 按下
    │
    ├── 有 FN+key 快捷键配置？
    │       │
    │   ┌── NO ─────────────────────────────────────────────────────────┐
    │   │   立即触发 commitDown('FN')（零延迟）                          │
    │   └────────────────────────────────────────────────────────────────┘
    │       │
    │   ┌── YES ─────────────────────────────────────────────────────────┐
    │   │   进入"combo ready"状态，等待...                               │
    │   │       │                                                         │
    │   │       ├── 在 FN 按住期间，有其他键按下？                        │
    │   │       │       └── YES → 立即触发 commitDown('FN+X')            │
    │   │       │             fnComboUsed = true                          │
    │   │       │                                                         │
    │   │       └── FN 松开，且期间无组合键触发（fnComboUsed = false）？  │
    │   │             └── YES → 触发 commitDown('FN')（纯 FN）           │
    │   └────────────────────────────────────────────────────────────────┘
```

**关键点**：
- 若系统中**没有**配置任何 `FN+key` 类快捷键，FN 键按下时**立即**触发（零延迟）
- 若系统中**有** `FN+key` 类快捷键，FN 键需要等到松开时才能确认是否为纯 FN
- 绝不使用定时器，避免引入固定延迟

### 6.3 FN 键事件流

FN 键事件**不经过 uiohook**，而是通过 Rust CGEventTap 直接回调到 JS：

```
物理 FN 按下
    │
    ▼
CGEventTap (Rust, kCGEventFlagsChanged + FN_KEY_MASK)
    │  消费事件（系统不会看到 FN 按下）
    │  同时抑制 Globe Emoji（TIS API）
    ▼
channel.send(FnEvent::Press)
    │
    ▼
FnKeySource.onPress callback
    │
    ▼
ShortcutMatcher.handleFnPress()
```

### 6.4 FN 键相关快捷键在 Capture 模式中的特殊处理

在快捷键录制（Capture）模式下：
- `interceptFnKey = true`：仍然抑制 Globe Emoji，但 FN 按下/松开事件通过 `CaptureRelay` 转发到渲染进程
- `interceptKeyCodesWhenFnDown = []`：**不**消费任何 FN+key 组合，让用户可以录制 FN+任意键作为新快捷键
- `interceptShortcuts = []`：**不**消费任何已配置的快捷键组合，让用户可以录制这些组合

---

## 7. 快捷键录制（Capture）模式

### 7.1 进入/退出流程

```
用户点击设置中的快捷键输入框
    │
    ▼
startEdit() [前端]
    │
    ├── enterCapture() [IPC → 主进程]
    │       │
    │       ├── 停止 FnKeySource（旧监听器）
    │       ├── 停止 UiohookSource（旧监听器）
    │       ├── 以 Capture 模式重启 FnKeySource
    │       │     onPress → captureRelay.emitFnPress()
    │       │     onRelease → captureRelay.emitFnRelease()
    │       ├── 以 Capture 模式重启 UiohookSource
    │       │     onKeyDown → captureRelay.emitKeyDown(keycode)
    │       │     onKeyUp → captureRelay.emitKeyUp(keycode)
    │       └── CGEventTap 参数：
    │             interceptFnKey = true    （仍然抑制 Emoji）
    │             interceptKeyCodesWhenFnDown = []  （不消费任何键）
    │             interceptShortcuts = []           （不消费任何键）
    │
    └── onCaptureKey(handleCaptureKeyEvent) [订阅 IPC 事件]
```

### 7.2 Capture 期间的按键识别流程

```
用户按键
    │
    ▼
uiohook keycode → captureRelay.emitKeyDown(keycode)
    │
    ▼
KEYCODE_TO_NAME[keycode]
    │  例：3640 → "RightAlt"
    ▼
IPC: hotkey:capture-key { key: "RightAlt", type: "down" }
    │
    ▼
handleCaptureKeyEvent [前端 React]
    │
    ├── 判断 key 是否在 UI_MODIFIER_KEYS 中？
    │       UI_MODIFIER_KEYS = {
    │         'FN', 'LeftShift', 'RightShift',
    │         'LeftControl', 'RightControl',
    │         'LeftAlt', 'RightAlt',
    │         'LeftCommand', 'RightCommand'  ← 前端名称，后端叫 LeftMeta/RightMeta
    │       }
    │
    ├── YES（修饰键）→ 加入 mods 集合
    └── NO（主键）→ 设置为 mainKey
    │
    ▼
recordingKeys = [...orderedMods, mainKey]
    │
    ▼
formatShortcut(recordingKeys) → 生成 electron 快捷键字符串
    │
    ▼
updateActionShortcuts(actionId, [electronShortcut]) [保存]
```

### 7.3 FN 键在 Capture 模式中的前端处理

FN 键通过独立 IPC 通道传递状态：
- `hotkey:fn-state { pressed: true/false }` → 前端设置 `fnHeld` 状态
- FN held + 其他键按下 → `recordingKeys = ['FN', ...otherKeys]`
- FN 单独按下再松开（无其他键）→ `recordingKeys = ['FN']`

---

## 8. 快捷键字符串格式与规范化

### 8.1 输入格式（宽松）

快捷键字符串采用 `+` 分隔的键名，大小写不敏感，支持多种别名：

```
"FN"
"FN+T"
"RightAlt"
"RightOption"        ← 与 RightAlt 等价
"Cmd+Shift+T"        ← Cmd 等价于 LeftMeta
"CommandOrControl+T" ← macOS 上等价于 Meta+T，Windows/Linux 上等价于 Ctrl+T
"LeftShift+RightAlt+Space"
```

### 8.2 规范化输出（确定性）

经过 `normalizeShortcut()` 处理后，所有等价写法统一为标准形式：

**修饰键顺序**（固定）：
```
FN → LeftControl → LeftShift → LeftAlt → LeftMeta
   → RightControl → RightShift → RightAlt → RightMeta
   → 主键（MainKey）
```

**规范化示例**：

| 输入 | 规范化结果 |
|------|----------|
| `"FN"` | `"FN"` |
| `"FN+T"` | `"FN+T"` |
| `"RightOption"` | `"RightAlt"` |
| `"RightCommand"` | `"RightMeta"` |
| `"Cmd+Shift+T"` | `"LeftShift+LeftMeta+T"` |
| `"CTRL+ALT+DELETE"` | `"LeftControl+LeftAlt+Delete"` |
| `"CommandOrControl+T"` | `"LeftMeta+T"`（macOS）或 `"LeftControl+T"`（Windows） |

### 8.3 前端 → 后端键名映射

前端 UI 使用的键名与后端存储的键名存在以下差异：

| 前端（UI） | 后端（快捷键字符串） |
|-----------|------------------|
| `LeftCommand` | `LeftMeta` |
| `RightCommand` | `RightMeta` |
| `LeftAlt` | `LeftAlt`（一致） |
| `RightAlt` | `RightAlt`（一致） |
| `FN` | `FN`（一致） |

转换通过 `UI_TO_ELECTRON_MAP` 完成：

```typescript
const UI_TO_ELECTRON_MAP = {
  LeftCommand: 'LeftMeta',
  RightCommand: 'RightMeta',
  // 其他键名一致，直接透传
}
```

---

## 9. 快捷键匹配状态机

### 9.1 状态

```
modifiers: ModifierFlags   // 当前按住的修饰键（左右分别追踪）
activeShortcut: string     // 当前激活的快捷键（同一时间只能有一个）
lastDownTime: number       // 上次触发 commitDown 的时间戳
fnPressed: boolean         // FN 键是否按住
fnComboUsed: boolean       // FN 按住期间是否触发过组合键
```

### 9.2 键事件处理顺序（handleKeyDown）

```
1. FN 按住中？
   └── YES → 检查 FN+key 组合匹配 → 匹配到 → fnComboUsed=true + commitDown
              └── 注意：此步骤在 updateModifier 之前，避免主键污染修饰键状态

2. 检查单键快捷键（无修饰键）
   └── 匹配到 → commitDown
              └── 注意：此步骤也在 updateModifier 之前

3. updateModifier(keycode, true)  ← 更新修饰键状态

4. 检查修饰键+主键组合
   └── 匹配到 → commitDown
```

### 9.3 修饰键状态追踪

左右修饰键**分别独立追踪**：

| 按键 | uiohook keycode | 对应状态 |
|------|----------------|---------|
| 左 Shift | 42 | `modifiers.shiftLeft` |
| 右 Shift | 54 | `modifiers.shiftRight` |
| 左 Control | 29 | `modifiers.controlLeft` |
| 右 Control | 3613 | `modifiers.controlRight` |
| 左 Alt | 56 | `modifiers.altLeft` |
| 右 Alt | 3640 | `modifiers.altRight` |
| 左 Meta | 3675 | `modifiers.metaLeft` |
| 右 Meta | 3676 | `modifiers.metaRight` |
| FN | N/A（不经 uiohook） | `modifiers.fn`（由 handleFnPress 设置） |

### 9.4 修饰键匹配规则

采用**精确匹配**（`modifiersMatch`）：快捷键定义中的每一个修饰键位，都必须与当前状态完全一致：

```typescript
// 要求 FN=on, 其他所有修饰键=off → 才能匹配 "FN+T"
!!required.fn === !!this.modifiers.fn &&
!!required.shiftLeft === !!this.modifiers.shiftLeft &&
... （共 9 个修饰键位，全部精确匹配）
```

---

## 10. 时序参数

| 参数名 | 值 | 说明 |
|--------|---|------|
| `KEY_DEBOUNCE_TIME` | **50ms** | 两次快捷键触发之间的最小间隔。如果两次 keydown 间隔 < 50ms，第二次被丢弃，防止重复触发 |
| `MIN_PRESS_DURATION` | **32ms** | 最小按压时长（约 2 帧，60fps）。如果 keyup 时距离 keydown < 32ms，延迟到满足时长再触发 onShortcutUp |

**32ms 的意义**：对应 60fps 屏幕的约 2 帧时长，防止意外轻触触发录音后立即停止，确保录音有最小持续时间。

---

## 11. 跨平台差异

### 11.1 macOS

- **两个监听层都工作**：CGEventTap（HID）+ uiohook（会话）
- **FN/Globe 键**通过 CGEventTap 专门处理
- **Globe Emoji 抑制**通过 TIS API 完成
- **Accessibility 权限**：uiohook 需要辅助功能权限；CGEventTap 需要独立的辅助功能权限
- **权限丢失检测**：每 2000ms 检查一次辅助功能权限；若权限被撤销，停止监听并通知用户

### 11.2 Windows / Linux

- **只有 uiohook 层**（无 CGEventTap）
- **没有 FN 键监听**（FN 键在 Windows/Linux 通常由硬件/BIOS 处理，不经过 OS）
- **Globe Emoji 抑制**不适用
- **CommandOrControl** 在非 macOS 平台解析为 `LeftControl`

---

## 附录：完整按键支持速查表

### 可用作独立快捷键

| 类别 | 按键 |
|------|------|
| FN 键 | FN |
| 右侧修饰键 | RightShift, RightControl, RightAlt, RightMeta |
| 符号键 | `[` `]` `;` `'` `.` `/` `,` |
| 导航键 | Up, Down, Left, Right, PageUp, PageDown, Home, End |
| Delete | Delete |

### 可用作组合快捷键的主键（必须搭配修饰键）

| 类别 | 按键 |
|------|------|
| 字母 | A-Z |
| 数字 | 0-9 |
| 符号 | `` ` `` / `~` |
| 以上独立键 | 上表中所有键也可搭配修饰键使用 |

### 禁止使用的按键（任何情况）

| 类别 | 按键 |
|------|------|
| 功能键 | F1-F12 |
| 系统特殊键 | Escape, Tab, Enter, Backspace |
| 左侧修饰键（单独使用） | LeftShift, LeftControl, LeftAlt, LeftMeta |
