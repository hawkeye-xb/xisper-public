# Xisper 快捷键系统技术实现文档

> **当前支持范围**：macOS 平台 + 免提（Hands-Free Toggle）模式。
>
> 本文档聚焦于这一约束下的实际实现。不涉及长按（Push-to-Talk）模式（当前未暴露给用户），不涉及 Windows/Linux（当前未支持）。

---

## 目录

1. [系统架构](#1-系统架构)
2. [第一层：CGEventTap HID 拦截](#2-第一层cgeventtap-hid-拦截)
3. [第二层：uiohook-napi 会话层监听](#3-第二层uiohook-napi-会话层监听)
4. [Globe Emoji 抑制机制](#4-globe-emoji-抑制机制)
5. [ShortcutMatcher 状态机](#5-shortcutmatcher-状态机)
6. [FN 键特殊处理流程](#6-fn-键特殊处理流程)
7. [免提模式下的按键行为](#7-免提模式下的按键行为)
8. [快捷键规则](#8-快捷键规则)
9. [系统模式切换（NORMAL / CAPTURE / DISABLED）](#9-系统模式切换normal--capture--disabled)
10. [快捷键录制（Capture 模式）](#10-快捷键录制capture-模式)
11. [关键时序参数](#11-关键时序参数)
12. [系统权限与可靠性](#12-系统权限与可靠性)
13. [核心文件索引](#13-核心文件索引)

---

## 1. 系统架构

Xisper 采用**双层拦截架构**，两层各司其职：

```
物理按键（用户按下）
        │
        ▼
┌───────────────────────────────────────────────────────┐
│  Layer 1: Rust CGEventTap（kCGHIDEventTap）           │
│  文件：packages/fn-key-monitor/src/platform/macos.rs  │
│                                                       │
│  职责：                                               │
│  ① FN/Globe 键的独占监听（消费事件）                   │
│  ② Globe Emoji 抑制（TIS API）                        │
│  ③ 白名单内 FN+key 组合的 HID 层消费                   │
│  ④ 白名单内修饰键+主键组合的 HID 层消费                 │
└───────────────────────────────┬───────────────────────┘
                                │ 未被消费的事件继续传递
                                ▼
┌───────────────────────────────────────────────────────┐
│  Layer 2: uiohook-napi（会话级键盘钩子）               │
│  文件：apps/desktop/src/main/hotkey/input/            │
│        uiohook-source.ts                              │
│                                                       │
│  职责：                                               │
│  ① 监听所有非 FN 键的 keydown / keyup                  │
│  ② 向 ShortcutMatcher 推送事件                         │
└───────────────────────────────┬───────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────┐
│  ShortcutMatcher（TypeScript 状态机）                  │
│  文件：apps/desktop/src/main/hotkey/shortcut/         │
│        matcher.ts                                     │
│                                                       │
│  职责：                                               │
│  ① 维护修饰键状态（左右分别追踪）                       │
│  ② FN 歧义消除（无定时器）                             │
│  ③ 快捷键匹配                                         │
│  ④ 防抖 + 最小按压时长校验                             │
│  ⑤ 触发 onShortcutDown / onShortcutUp 回调             │
└───────────────────────────────┬───────────────────────┘
                                │
                 ┌──────────────┴────────────────┐
                 ▼                               ▼
        onShortcutDown                   onShortcutUp
    dispatchAction('keydown')        dispatchAction('keyup')
              │                               │
              ▼                               ▼
    录音 Action 执行                   录音 Action 执行
    免提模式：切换录音开/关            免提模式：忽略（不停止录音）
```

---

## 2. 第一层：CGEventTap HID 拦截

### 2.1 注册参数

```rust
// CGEventTapCreate 参数
location  = kCGHIDEventTap      // 0 — 最早的拦截点（HID 硬件事件层）
placement = kCGHeadInsertEventTap // 0 — 插在事件链最前端，优先级最高
options   = kCGEventTapOptionDefault // 0 — 可修改/消费事件（默认模式）

// 监听的事件类型
kCGEventKeyDown       = 10  // 按键按下
kCGEventKeyUp         = 11  // 按键抬起
kCGEventFlagsChanged  = 12  // 修饰键/FN 状态变化
```

### 2.2 拦截白名单（3 种）

| 类型 | 触发条件 | 处理 |
|------|---------|------|
| **FN 键本身** | `event_type == kCGEventFlagsChanged && FN_KEY_MASK` | 消费（返回 `null_mut()`），通知 JS 层 |
| **FN + 主键组合** | `fn_state == true && keycode ∈ interceptKeyCodesWhenFnDown` | 消费（返回 `null_mut()`） |
| **修饰键 + 主键组合** | `current_mods == required_mods && keycode == required_keycode`（精确等号匹配） | 消费（返回 `null_mut()`） |

### 2.3 修饰键掩码

```
SHIFT_MASK   = 0x20000
CONTROL_MASK = 0x40000
ALT_MASK     = 0x80000   (Option)
COMMAND_MASK = 0x100000
FN_KEY_MASK  = 0x800000
```

### 2.4 精确匹配的必要性

拦截非 FN 快捷键时，使用 `current_mods == required_mods`（等于）而非 `current_mods & required_mods != 0`（位与）：

- 配置了 `Cmd+T`：按 `Ctrl+Cmd+T` **不会**被拦截（多了 Ctrl）
- 配置了 `Cmd+Shift+T`：按 `Cmd+T` **不会**被拦截（少了 Shift）

这保证了精准拦截，不干扰相似但不完全匹配的系统组合键。

### 2.5 拦截白名单的动态构建

白名单由配置驱动，在 `HotkeySystem.getInterceptOptions()` 中根据当前已配置的快捷键实时生成：

```typescript
// hotkey-system.ts
private getInterceptOptions() {
  const interceptFnKey = shortcuts.has('FN')

  for (const shortcut of shortcuts) {
    if (shortcut.startsWith('FN+')) {
      // FN+T → interceptKeyCodesWhenFnDown.push(0x11)  (T 的 Carbon 码)
    } else {
      // Cmd+T → interceptShortcuts.push({ modifierMask: 0x100000, keycode: 0x11 })
    }
  }
}
```

---

## 3. 第二层：uiohook-napi 会话层监听

### 3.1 作用范围

- 监听**所有未被 HID 层消费**的 keydown / keyup 事件
- 使用 uiohook keycode 体系（与 Carbon Virtual Key Code 不同）
- 将事件推送给 `ShortcutMatcher`

### 3.2 关键 uiohook keycode

| 按键 | uiohook keycode |
|------|----------------|
| RightShift | 54 |
| RightControl | 3613 |
| RightAlt（RightOption） | 3640 |
| RightMeta（RightCommand） | 3676 |
| LeftShift | 42 |
| LeftControl | 29 |
| LeftAlt | 56 |
| LeftMeta | 3675 |
| Space | 57 |
| FN | N/A（不经过 uiohook，由 CGEventTap 独占） |

### 3.3 为什么需要两层

FN/Globe 键**不会**产生标准的 `kCGEventKeyDown` 事件，只产生 `kCGEventFlagsChanged` 事件（FN_KEY_MASK 变化），且 uiohook 无法感知到它。因此 FN 键必须由 CGEventTap 专门处理；其他键则由 uiohook 覆盖。

---

## 4. Globe Emoji 抑制机制

### 4.1 问题背景

在 Apple Silicon Mac 上，FN/Globe 键默认触发 Emoji 选择器（`AppleFnUsageType = 2`）。如果 Xisper 使用 FN 键作为快捷键，必须抑制该行为。

### 4.2 技术方案：TIS 私有 API

通过 `dlopen`/`dlsym` 动态加载 HIToolbox 框架中的私有函数：

```rust
// packages/fn-key-monitor/src/platform/macos.rs
// 框架路径：Carbon.framework/.../HIToolbox.framework
fn tis_get_fn_usage_type() -> i32  // 读取当前设置
fn tis_set_fn_usage_type(v: i32)   // 写入新设置

// AppleFnUsageType 取值
// 0 = Do Nothing（Xisper 设置的值）
// 1 = Change Input Source
// 2 = Show Emoji & Symbols（Apple Silicon 默认）
// 3 = Start Dictation
```

这个 API 会**实时广播 TIS 通知**给 `TextInputSwitcher` / `keyboardservicesd`，令 `isFnForEmoji` 状态立即更新，无需重启任何系统服务。

### 4.3 Bounce 机制

```typescript
// fn-key-source.ts
function writeGlobeKeyBehavior(value: number): void {
  const current = getFn()
  if (current === value) {
    setFn(value === 0 ? 1 : 0)  // 先设置一个不同的值，强制触发 TIS 通知
  }
  setFn(value)                   // 再设置目标值
}
```

若当前值已等于目标值，直接设置不会触发通知，因此先"弹一下"再设回去。

### 4.4 生命周期

| 时机 | 操作 |
|------|------|
| `start()` 且 `interceptFnKey = true` | `AppleFnUsageType → 0`（禁用 Emoji） |
| `stop()` | `AppleFnUsageType → 原始值`（还原） |
| `app.before-quit` | 同 `stop()`，确保退出时还原 |

---

## 5. ShortcutMatcher 状态机

### 5.1 内部状态

```typescript
class ShortcutMatcher {
  private modifiers: ModifierFlags = {
    fn, shiftLeft, shiftRight,
    controlLeft, controlRight,
    altLeft, altRight,
    metaLeft, metaRight
  }
  private activeShortcut: string | null = null  // 当前激活中的快捷键
  private lastDownTime: number = 0              // 上次 commitDown 的时间戳

  // FN 专用状态
  private fnOnlyShortcut: ParsedShortcut | null   // 是否配置了纯 FN 快捷键
  private hasFnComboShortcuts: boolean            // 是否配置了 FN+key 组合
  private fnPressed: boolean = false              // FN 当前是否按住
  private fnComboUsed: boolean = false            // FN 按住期间是否触发过组合键
}
```

### 5.2 handleKeyDown 处理顺序

```
handleKeyDown(keycode)
    │
    ├── 1. [FN 按住中] 检查 FN+key 组合匹配
    │         └── 匹配 → fnComboUsed=true, updateModifier, commitDown('FN+X'), return
    │   ⚠️ 在 updateModifier 之前检查，防止主键（也是修饰键时）污染修饰键状态
    │
    ├── 2. 检查无修饰键的独立快捷键（如 RightAlt 单独使用）
    │         └── 匹配 → commitDown('RightAlt'), return
    │   ⚠️ 同样在 updateModifier 之前，防止 RightAlt 被加入修饰键状态后误判
    │
    ├── 3. updateModifier(keycode, true)  ← 更新修饰键状态
    │
    └── 4. 检查修饰键 + 主键组合（如 Cmd+T）
              └── 匹配 → commitDown('LeftMeta+T'), return
```

### 5.3 修饰键精确匹配

```typescript
private modifiersMatch(required: ModifierFlags): boolean {
  return (
    !!required.fn          === !!this.modifiers.fn          &&
    !!required.shiftLeft   === !!this.modifiers.shiftLeft   &&
    !!required.shiftRight  === !!this.modifiers.shiftRight  &&
    !!required.controlLeft === !!this.modifiers.controlLeft &&
    // ...共 9 个修饰键位，全部精确匹配（等于，非包含）
  )
}
```

---

## 6. FN 键特殊处理流程

### 6.1 两类 FN 使用场景

| 使用场景 | 快捷键字符串 | 举例 |
|---------|------------|------|
| FN 单独使用 | `FN` | 按一下 FN → 切换录音 |
| FN 作为修饰键 | `FN+Space` | FN 按住 + Space → 进入免提模式 |

### 6.2 无定时器歧义消除

当 FN 按下时，系统无法立即判断用户是想用"纯 FN"还是"FN+key"。Xisper 采用**无定时器**的确定性方案：

```
FN 按下（handleFnPress）
    │
    ├── 没有配置任何 FN+key 组合快捷键？
    │       └── 立即 commitDown('FN')（零延迟，直接触发）
    │
    └── 有配置 FN+key 组合快捷键？
            └── 进入等待状态（fnPressed=true, fnComboUsed=false）
                    │
                    ├── 在 FN 按住期间有其他键按下？
                    │       └── fnComboUsed=true, commitDown('FN+X')
                    │
                    └── FN 松开 且 fnComboUsed=false？
                            └── commitDown('FN')（确认为纯 FN）
```

### 6.3 免提模式下的 FN 歧义问题

**当同时配置了 `FN`（免提触发）和 `FN+Space`（进入免提模式）时**：

1. 用户按下 FN → 系统进入等待状态（因为有 FN+Space 配置）
2. 用户松开 FN 时：
   - 若中途没按 Space → `commitDown('FN')` → 切换录音状态（免提触发）
   - 若中途按了 Space → `commitDown('FN+Space')` → 进入/退出免提模式

**代价**：当同时配置了 FN+key 时，纯 FN 的触发时机是**松开时**，而不是按下时。这对免提模式是一个潜在的延迟感知问题（用户按下 → 松开才生效）。

---

## 7. 免提模式下的按键行为

> 注意：免提模式的"Toggle"逻辑由录音 Action 本身实现，ShortcutMatcher 层仅负责报告 down/up 事件。

### 7.1 事件流

```
用户按下快捷键（如 FN）
    │
    ▼ ShortcutMatcher
commitDown('FN')
    │
    ▼ HotkeySystem.dispatchAction('FN', 'keydown')
    │
    ▼ 录音 Action.execute(event: { type: 'keydown' })
    │
    ├── 当前未录音 → 开始录音（免提拨动 ON）
    └── 当前录音中 → 停止录音 + 插入文字（免提拨动 OFF）


用户松开快捷键（如 FN）
    │
    ▼ ShortcutMatcher
commitUp('FN')
    │
    ▼ HotkeySystem.dispatchAction('FN', 'keyup')
    │
    ▼ 录音 Action.execute(event: { type: 'keyup' })
    │
    └── 免提模式：忽略 keyup，什么都不做
```

### 7.2 防抖与最小时长（与免提的关系）

| 参数 | 值 | 免提模式的意义 |
|------|---|------------|
| `KEY_DEBOUNCE_TIME` | 50ms | 防止同一快捷键 50ms 内重复触发（防误触，有用） |
| `MIN_PRESS_DURATION` | 32ms | 延迟 keyup 直到按压 ≥ 32ms 才触发（对免提模式的 keyup 无实际作用） |

> **当前冗余**：`MIN_PRESS_DURATION` 是为长按模式设计的（确保录音有最小时长），在免提模式下 keyup 被忽略，该校验等于空转。

---

## 8. 快捷键规则

### 8.1 可独立使用的按键

| 类别 | 按键 |
|------|------|
| FN 键 | FN |
| 右侧修饰键 | RightShift（54）、RightControl（3613）、RightAlt（3640）、RightMeta（3676） |
| 符号键 | `[` `]` `;` `'` `.` `/` `,` |
| 导航键 | Up, Down, Left, Right, PageUp, PageDown, Home, End |
| Delete | Delete |

### 8.2 必须搭配修饰键

| 类别 | 按键 |
|------|------|
| 字母 | A-Z（26 个） |
| 数字 | 0-9（10 个） |
| 波浪线 | `` ` ``、`~` |

### 8.3 完全禁止

| 类别 | 按键 |
|------|------|
| 功能键 | F1-F12 |
| 系统特殊键 | Escape、Tab、Enter、Backspace |
| 左侧修饰键（单独） | LeftShift、LeftControl、LeftAlt、LeftMeta（及所有别名） |

### 8.4 最大组合键数

`MAX_KEY_COMBINATION_COUNT = 3`（最多 3 个主键同时按下）

---

## 9. 系统模式切换（NORMAL / CAPTURE / DISABLED）

`HotkeySystem` 维护三种运行模式，转换关系如下：

```
DISABLED ──initialize()──► NORMAL ──enterCapture()──► CAPTURE
                              │                          │
                              ◄──────exitCapture()───────┘
                              │
                       disable()/enable()
```

### 9.1 NORMAL 模式

- `FnKeySource` 运行，监听 FN press/release → `ShortcutMatcher`
- `UiohookSource` 运行（若有非 FN 快捷键），监听 keydown/keyup → `ShortcutMatcher`
- CGEventTap 白名单：当前所有已配置快捷键的 HID 层消费

### 9.2 CAPTURE 模式（快捷键录制）

- `FnKeySource` 运行，但只将事件转发给 `CaptureRelay`，不走 `ShortcutMatcher`
- `UiohookSource` 运行，同样只转发给 `CaptureRelay`
- **关键**：`interceptKeyCodesWhenFnDown = []`，`interceptShortcuts = []`
  → 任何键都不会被 HID 层消费，用户可以录制任意快捷键（包括当前已配置的）
- `interceptFnKey` 保留 → 仍然抑制 Globe Emoji

---

## 10. 快捷键录制（Capture 模式）

### 10.1 完整流程

```
前端：用户点击快捷键输入框
    │
    ▼ IPC: enterCapture(windowId)
    │
    ▼ 主进程 HotkeySystem.enterCapture()
    │
    ├── matcher.reset()
    ├── captureRelay.start(windowId)
    ├── fnSource.restart(captureCallbacks, {interceptKeyCodesWhenFnDown:[], interceptShortcuts:[]})
    └── uiohookSource.restart({ onKeyDown: relay.emitKeyDown, onKeyUp: relay.emitKeyUp })

    按键事件 → KEYCODE_TO_NAME[keycode] → IPC: hotkey:capture-key { key, type }
              （如 3640 → "RightAlt"）
    FN 事件  → IPC: hotkey:fn-state { pressed: true/false }

    ▼ 前端 handleCaptureKeyEvent()
    │
    ├── 判断 key 是否在 UI_MODIFIER_KEYS 中？
    │   YES → 加入 mods
    │   NO  → 设为 mainKey
    │
    └── recordingKeys = [...orderedMods, mainKey]
            │
            ▼ formatShortcut(recordingKeys) → 生成标准快捷键字符串
            │
            ▼ updateActionShortcuts(actionId, [shortcutString])
```

### 10.2 keycode 到按键名映射（捕获层）

| uiohook keycode | 按键名（捕获层输出） |
|----------------|------------------|
| 42 | LeftShift |
| 54 | RightShift |
| 29 | LeftControl |
| 3613 | RightControl |
| 56 | LeftAlt |
| 3640 | RightAlt |
| 3675 | LeftMeta |
| 3676 | RightMeta |
| FN | FN（独立通道） |

---

## 11. 关键时序参数

| 参数 | 值 | 设计意图 | 免提模式下的实际意义 |
|------|---|---------|------------------|
| `KEY_DEBOUNCE_TIME` | 50ms | 防止同一快捷键短时间内重复触发 | **有效**：防止双击误触切换两次状态 |
| `MIN_PRESS_DURATION` | 32ms | 确保录音不会因意外轻触立即停止（≈2帧@60fps） | **冗余**：免提模式下 keyup 被忽略，此校验空转 |

---

## 12. 系统权限与可靠性

### 12.1 所需权限

| 权限 | 用途 |
|------|------|
| **辅助功能（Accessibility）** | uiohook 会话级监听；CGEventTap 消费事件 |

### 12.2 权限丢失检测

`UiohookSource` 每 2000ms 检查一次辅助功能权限：
- 若权限被撤销 → 停止所有监听 → 触发 `accessibility-permission-lost` 事件 → 通知用户

---

## 13. 核心文件索引

| 职责 | 文件路径 |
|------|---------|
| HID 层拦截（Rust） | `packages/fn-key-monitor/src/platform/macos.rs` |
| Rust NAPI 导出 | `packages/fn-key-monitor/src/lib.rs` |
| TS 类型声明 | `packages/fn-key-monitor/index.d.ts` |
| FN 键源（含 Globe Emoji 抑制） | `apps/desktop/src/main/hotkey/input/fn-key-source.ts` |
| uiohook 会话源 | `apps/desktop/src/main/hotkey/input/uiohook-source.ts` |
| **状态机核心** | `apps/desktop/src/main/hotkey/shortcut/matcher.ts` |
| 快捷键解析 | `apps/desktop/src/main/hotkey/shortcut/parser.ts` |
| 快捷键验证 | `apps/desktop/src/main/hotkey/shortcut/validator.ts` |
| **系统协调器** | `apps/desktop/src/main/hotkey/hotkey-system.ts` |
| 常量（keycodes、规则） | `apps/desktop/src/main/hotkey/constants.ts` |
| 捕获模式中继 | `apps/desktop/src/main/hotkey/capture-relay.ts` |
