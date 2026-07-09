# 快捷键实现方式对比：Typeless vs Xisper

> **比较前提**：Xisper 当前仅支持 **macOS** + **免提（Hands-Free Toggle）模式**，不支持长按（Push-to-Talk）模式。
>
> **数据来源**：两份文档均基于真实源码分析，非推断。
> - Typeless：`/Applications/Typeless.app/Contents/Resources/app.asar`（解包）+ Swift dylib 反编译
> - Xisper：`apps/desktop/src/main/hotkey/` + `packages/fn-key-monitor/src/`

---

## 目录

1. [技术栈对比（实际代码）](#1-技术栈对比实际代码)
2. [架构层数对比](#2-架构层数对比)
3. [键盘监听机制对比](#3-键盘监听机制对比)
4. [快捷键匹配位置对比](#4-快捷键匹配位置对比)
5. [FN 键处理策略对比](#5-fn-键处理策略对比)
6. [Tap vs Hold 歧义消除对比](#6-tap-vs-hold-歧义消除对比)
7. [按键按下行为对比](#7-按键按下行为对比)
8. [按键抬起行为对比](#8-按键抬起行为对比)
9. [快捷键规则对比](#9-快捷键规则对比)
10. [Globe Emoji 抑制对比](#10-globe-emoji-抑制对比)
11. [冗余机制分析（macOS + 免提约束下）](#11-冗余机制分析macos--免提约束下)
12. [综合评分](#12-综合评分)
13. [结论与建议](#13-结论与建议)

---

## 1. 技术栈对比（实际代码）

| 维度 | Typeless | Xisper |
|------|---------|--------|
| **宿主框架** | Electron | Electron |
| **原生键盘库语言** | **Swift** | **Rust** |
| **JS → 原生桥接** | **koffi**（FFI，运行时加载 `.dylib`） | **NAPI**（编译时生成 `.node`） |
| **原生库分发方式** | 预编译 `.dylib`（无需用户机器构建） | CI 构建 `.node`（需 Rust 工具链） |
| **底层键盘 API** | CGEventTap（CoreGraphics + Carbon） | CGEventTap（CoreGraphics，kCGHIDEventTap） |
| **会话层键盘监听** | ❌ 无（只用 Swift CGEventTap 一层） | ✅ uiohook-napi（第二层，跨平台） |
| **状态机** | XState（渲染进程） | 自定义 TypeScript 类（主进程） |
| **Globe Emoji 抑制** | Swift dylib 内部处理（方式未知） | TIS 私有 API（`TISUpdateFnUsageType`，dlopen） |

**关键发现（实际代码证实）**：
- 两者都是 Electron 应用
- 两者都用 CGEventTap，但 **Typeless 是 Swift 实现，Xisper 是 Rust 实现**
- Typeless 用 **koffi（FFI）**，不需要编译；Xisper 用 **NAPI**，需要 Rust 编译链
- Typeless **没有** uiohook 层，只有一个 Swift CGEventTap

---

## 2. 架构层数对比

### Typeless（3 层）

```
物理按键
    │
    ▼ [Layer 1] Swift CGEventTap（ShortcutDetector）
      - 报告当前全部按下的键（state-based）
      - koffi FFI 回调到主进程 JS
    │
    ▼ [Layer 2] 主进程 JS（KeyboardInputService）
      - throttle 16ms 广播到渲染进程
    │
    ▼ [Layer 3] 渲染进程（hC hook + XState）
      - 匹配快捷键 → 状态机转换 → 录音开始/切换
```

### Xisper（5 层）

```
物理按键
    │
    ▼ [Layer 1] Rust CGEventTap（kCGHIDEventTap，FN 专属 + 白名单消费）
    │
    ▼ [Layer 2] uiohook-napi（会话级键盘钩子，非 FN 键）
    │
    ▼ [Layer 3] ShortcutMatcher TypeScript（修饰键追踪、歧义消除、防抖）
    │
    ▼ [Layer 4] HotkeySystem TypeScript（协调器，NORMAL/CAPTURE/DISABLED 模式）
    │
    ▼ [Layer 5] 录音 Action（录音开始/切换）
```

**判定**：Typeless 3 层更简洁，Xisper 5 层对于 macOS + 免提模式而言是过度设计。

---

## 3. 键盘监听机制对比

### Typeless：**Key-State 模型**（当前全部按键的集合快照）

```
每次 CGEventTap 触发
→ Swift 报告：目前按下了 {Fn, Space}（当前状态集合）
→ 变化了才触发回调（状态去重）
→ JS 收到：[{keyCode:63, keyName:"Fn"}, {keyCode:57, keyName:"Space"}]
```

- 回调参数是**当前全部按下的键**（不区分 keydown/keyup）
- 只关心"现在按着什么"，不关心哪个键刚被按下/松开
- 匹配逻辑：目标键是否全部在当前集合中（子集关系）

### Xisper：**Edge 模型**（keydown/keyup 事件驱动）

```
FN keydown  → Rust CGEventTap → JS onFnPress()  → handleFnPress()
FN keyup    → Rust CGEventTap → JS onFnRelease() → handleFnRelease()
T keydown   → uiohook → handleKeyDown(20)
T keyup     → uiohook → handleKeyUp(20)
```

- 分别处理 keydown 和 keyup 两个边沿事件
- 需要在 JS 维护修饰键状态（9 个修饰键位，逐一追踪）
- 匹配逻辑：当前修饰键状态 == 快捷键定义的修饰键状态（精确等号比较）

**对比分析**：

| 维度 | Typeless（State模型） | Xisper（Edge模型） |
|------|---------------------|-----------------|
| 实现复杂度 | 低（Swift 自动维护状态） | 高（JS 手动维护 9 个修饰键位） |
| 修饰键误判可能 | 低（当前状态即全量） | 中（keydown/keyup 乱序可能导致状态不一致） |
| 需要 keyup 感知 | ❌ 可不需要（State 自然消失） | ✅ 必需（Edge 需要明确 keyup） |
| 适合免提模式 | ✅ 天然（状态从 "按着FN" → "没按FN"） | 需额外设计（keyup 触发 commitUp，免提下无用） |

---

## 4. 快捷键匹配位置对比

| 匹配层 | Typeless | Xisper |
|--------|---------|--------|
| **第一次匹配** | Swift `ShortcutDetector`（Native，CGEventTap 内部） | 无 |
| **第二次匹配** | 渲染进程 `hC` hook（TypeScript，渲染进程） | 主进程 `ShortcutMatcher`（TypeScript，主进程） |
| **匹配结果触发** | XState 事件（渲染进程） | `dispatchAction`（主进程 → 录音 Action） |

**Typeless 的双重匹配**：
- Swift 层：粗粒度过滤（目标快捷键有变化时才触发 JS 回调）
- JS 渲染层：细粒度匹配（精确匹配 + misTouch 检测 + debounce）

**Xisper 的单层匹配**：
- 所有匹配逻辑集中在主进程 `ShortcutMatcher` TypeScript 类中
- 无渲染进程匹配，架构更清晰但灵活性略低

---

## 5. FN 键处理策略对比

### Typeless

- FN 键被 Swift CGEventTap 检测到，加入 `pressingKeycodes`
- Swift `ShortcutDetector` 将 FN 视为普通键（只是恰好是默认快捷键）
- **无 FN 专属通道**，FN 和其他键使用完全相同的处理路径
- Globe Emoji 抑制：推测在 Swift 层 CGEventTap 消费事件时实现

### Xisper

- FN 键通过**专属 Rust CGEventTap 通道**处理（`kCGEventFlagsChanged` + `FN_KEY_MASK`）
- FN 键事件**不经过 uiohook**
- FN 键需要专门的 `onFnPress`/`onFnRelease` 回调
- Globe Emoji 抑制：TIS 私有 API `TISUpdateFnUsageType(0)`（dlopen 动态加载）

**对比**：Typeless 对 FN 键无特殊处理，比 Xisper 简洁很多。Xisper 之所以需要专属通道，是因为 uiohook 无法感知 FN/Globe 键（它只发 `kCGEventFlagsChanged`，不发标准 `kCGEventKeyDown`）。

---

## 6. Tap vs Hold 歧义消除对比

这是两者设计差异最大的地方：

### Typeless：**基于计时器的 Tap/Hold 区分**（LONG_PRESS_MS）

```
FN 按下 → PRIMARY_KEY.DOWN → awaiting_long_press_or_tap
    │
    ├── LONG_PRESS_MS 内 FN 松开 → recording_active.handsFree（免提，继续录音）
    └── 超过 LONG_PRESS_MS → recording_active.pushToTalk（长按模式，按住录音）
```

- **有定时器**（`LONG_PRESS_MS`）
- 一个快捷键自动支持两种行为
- 快速轻按 = 免提；长按 = push-to-talk
- 有 `showDoNotHoldJustPressAlertAction`：提示长按用户改用轻按

### Xisper：**基于释放顺序的 FN/FN+key 区分**（无定时器）

```
FN 按下 → handleFnPress()
    │
    ├── 无 FN+key 快捷键配置 → 立即 commitDown('FN')（零延迟）
    └── 有 FN+key 快捷键配置 → 等待...
              │
              ├── 中途有其他键按下 → commitDown('FN+X')（FN+key 组合）
              └── FN 松开无组合 → commitDown('FN')（纯 FN）
```

- **无定时器**（确定性，基于事件顺序）
- 区分的是"FN 单独"vs"FN+key"，不区分快慢
- 不支持同一快捷键自动切换 tap/hold 行为

**对 Xisper（仅免提模式）的影响**：

当配置了 `FN`（切换录音）和 `FN+Space`（进入免提模式）时，Xisper 的 FN 触发时机是**松开时**（因为需要等待确认没有 FN+Space），而 Typeless 的 FN 触发是**按下时**（立即进入等待状态，并发起录音初始化）。

| 维度 | Typeless | Xisper（仅免提） |
|------|---------|----------------|
| 区分目的 | Tap（免提）vs Hold（长按）| FN alone vs FN+key combo |
| 使用定时器 | ✅ LONG_PRESS_MS | ❌ 无定时器（按事件顺序） |
| FN 按下时是否立即响应 | ✅ 立即初始化（initializingForTapOrHold） | ❌ 需等 FN 松开才确认是 FN-only |
| 支持同一键 tap/hold 双行为 | ✅ | ❌（无此设计） |
| 当前 Xisper 是否需要此特性 | - | ❌（仅免提，不需要 tap/hold 区分） |

---

## 7. 按键按下行为对比

### Typeless（免提模式下）

```
FN 按下（物理）
→ Swift pressingKeys 加入 FN → 回调 → throttle 16ms → 广播渲染进程
→ hC hook: isFullMatch("fn") = true → isShortcutActive = true（立即）
→ XState: PRIMARY_KEY.DOWN → initializingForTapOrHold → 开始录音初始化（并发）
```

- **按下时立即响应**（initializingForTapOrHold 立即开始）
- 定时器 LONG_PRESS_MS 决定最终落入哪个子状态

### Xisper（免提模式下，配置了 FN 且有 FN+key 快捷键）

```
FN 按下（物理）
→ Rust CGEventTap: 消费事件（FN 不传给系统）
→ JS: onFnPress() → matcher.handleFnPress()
  → fnPressed=true, fnComboUsed=false
  → 有 FN+key 配置 → 进入等待状态（无任何操作）

FN 松开（物理）
→ Rust CGEventTap → JS: onFnRelease() → matcher.handleFnRelease()
  → fnComboUsed==false → commitDown('FN')
  → onShortcutDown('FN') → dispatchAction → 切换录音状态
```

- **按下时无响应**，松开后才触发
- 用户按下 FN 到录音实际开始：有额外延迟（等松开 + 函数调用链）

**判定**：在免提模式下，Typeless 的按下即响应体验优于 Xisper 的延迟到松开。

---

## 8. 按键抬起行为对比

### 免提模式下，按键抬起的期望行为

| 模式 | 期望 |
|------|------|
| 免提（切换式） | 按下 = 切换；**松开 = 无操作** |
| 长按（push-to-talk） | 按下 = 开始；**松开 = 停止** |

### Typeless

**免提模式（recording_active.handsFree）下**：
- `PRIMARY_KEY.UP` 从 XState 状态的 `on` 事件中移除（该状态下 keyup 不触发停止）
- hC hook 检测到 `isShortcutActive = false`，但 XState 机器不响应
- **keyup 在免提模式下真正被忽略**

```typescript
recording_active.handsFree: {
  on: {
    // "PRIMARY_KEY.UP" 不在此处 ← 免提模式下 keyup 无效
    "PRIMARY_KEY.DOWN": { target: "stopping", actions: [...] }  // 再次按下 → 停止
  }
}
```

### Xisper

免提模式下，keyup 仍然走完整链路：

```
FN 松开（松开即 commitDown 后立即 commitUp）
→ commitUp('FN') → MIN_PRESS_DURATION 校验（32ms）
→ executeUp('FN') → onShortcutUp → dispatchAction('keyup')
→ 录音 Action: 判断是免提模式 → 忽略
```

- **keyup 被忽略了，但仍然走了全部代码路径**
- `MIN_PRESS_DURATION = 32ms` 校验对免提模式毫无意义，仍然执行

**判定**：Typeless 通过 XState 状态定义明确忽略 keyup；Xisper 走完全部链路后才忽略。Typeless 更高效。

---

## 9. 快捷键规则对比

| 规则 | Typeless | Xisper |
|------|---------|--------|
| **FN 键独立** | ✅ 默认快捷键 | ✅ |
| **右侧修饰键独立** | ✅（Swift 能检测，黑名单无限制） | ✅（明确允许，有专门 STANDALONE_ALLOWED_KEYS） |
| **左侧修饰键独立** | ⚠️ 技术可行，无明确禁止 | ❌ 明确禁止（STANDALONE_FORBIDDEN_KEYS） |
| **字母键独立** | ❌（规则②：纯字母不允许） | ❌ |
| **数字键独立** | ❌（规则②：纯数字不允许） | ❌ |
| **F1-F12** | ❌（黑名单） | ❌ |
| **Escape/Tab/Enter/Backspace/Space** | ❌（黑名单） | ❌ |
| **最大组合键数** | 3 | 3 |
| **连续字母（A+B）** | ❌（专门检查） | 未明确禁止（Xisper 无此规则） |
| **连续数字（1+2）** | ❌（专门检查） | 未明确禁止 |
| **系统保留精确黑名单** | ✅（LeftCmd+C 等 20+ 条） | ❌（无精确黑名单，靠其他规则覆盖） |
| **导航键（↑↓←→）独立** | 未明确限制 | ✅ 明确允许 |
| **符号键（[ ] ; '）独立** | 未明确限制 | ✅ 明确允许 |
| **录音时追加 Escape 快捷键** | ✅（动态加入 targetShortcuts） | ❌（无此机制） |

---

## 10. Globe Emoji 抑制对比

| 方面 | Typeless | Xisper |
|------|---------|--------|
| 实现位置 | Swift dylib 内部（具体 API 未知） | TypeScript `fn-key-source.ts` |
| 使用 API | 推测为 CGEventTap 直接消费 FN 事件 | `TISUpdateFnUsageType(0)`（私有 API，dlopen） |
| 还原时机 | 推测在 stopMonitor 时 | `stop()` + `app.before-quit` |
| Bounce 机制 | 未知 | ✅（强制 TIS 通知实时生效） |
| 生效方式 | 推测：消费事件使 Emoji 选择器看不到 FN | 直接修改系统配置，实时广播 TIS 通知 |

**Xisper 的 TIS API 方案更彻底**：即使出现事件泄漏（CGEventTap 未能消费某个 FN 事件），TIS 配置已经全局禁用了 Emoji 触发；Typeless 的方案若 CGEventTap 失效（如被系统禁用），Emoji 可能重新出现。

---

## 11. 冗余机制分析（macOS + 免提约束下）

### Typeless 在 macOS + 免提约束下

Typeless 的架构中，以下机制在**仅免提**场景下冗余：

| 机制 | 冗余原因 |
|------|---------|
| `LONG_PRESS_MS` 计时器 | 为 tap/hold 二义性设计；仅免提则"quick tap = toggle"始终成立，无需等时间 |
| `recording_active.pushToTalk` 子状态 | 免提下不会进入长按分支 |
| `showDoNotHoldJustPressAlertAction` | 提示用户"别按住"，仅免提下无意义 |

但 Typeless 的设计天然支持免提：
- hC hook 检测 `isShortcutActive` 变化即可驱动 XState
- 免提模式下 keyup 真正被 XState 忽略
- **总体冗余量 < Xisper**

### Xisper 在 macOS + 免提约束下

以下机制完全冗余：

| 机制 | 冗余原因 |
|------|---------|
| `MIN_PRESS_DURATION = 32ms` | 长按模式防轻触用；免提 keyup 被忽略，此校验空转 |
| `onShortcutUp` → `commitUp` → `executeUp` 整条链路 | 免提 Action 忽略 keyup，此链路无效执行 |
| uiohook-napi 跨平台适配 | 仅 macOS，跨平台层是未来准备，当前冗余 |
| FN 歧义消除（等松开才确认 FN-only） | 免提不需要区分 tap/hold；此等待带来不必要的响应延迟 |
| `interceptKeyCodesWhenFnDown` / `interceptShortcuts` 动态构建 | 仅当 `interceptSystem = true` 时有效；默认关，多数情况下构建后无用 |

---

## 12. 综合评分

> 在"macOS + 免提模式"约束下，1-5 分（5 最优）

| 维度 | Typeless | Xisper | 说明 |
|------|:-------:|:------:|------|
| **架构简洁度** | ⭐⭐⭐⭐ | ⭐⭐ | Typeless 3层 vs Xisper 5层 |
| **按下触发延迟** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | Typeless 按下即响应；Xisper FN 需等松开 |
| **keyup 处理效率** | ⭐⭐⭐⭐⭐ | ⭐⭐ | Typeless XState 直接忽略；Xisper 走全链路后忽略 |
| **冗余代码量** | ⭐⭐⭐⭐ | ⭐⭐ | Typeless 少量冗余；Xisper 有大量 PTT 专用逻辑 |
| **Globe Emoji 抑制** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Xisper TIS API 更彻底可靠 |
| **快捷键规则完整性** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Xisper 有更完整的验证（导航键/符号键明确允许） |
| **Capture 录制模式** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Xisper 有完善的快捷键录制流程 |
| **录音时 Escape 响应** | ⭐⭐⭐⭐⭐ | ⭐⭐ | Typeless 动态加入 Escape；Xisper 无此机制 |
| **原生桥接复杂度** | ⭐⭐⭐⭐⭐ | ⭐⭐ | koffi 无需编译；NAPI+Rust 需 CI 构建流程 |
| **调试难度** | ⭐⭐⭐⭐ | ⭐⭐ | Xisper 跨 Rust/TS/IPC 边界 |
| **未来扩展（长按 + 跨平台）** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Xisper 基础架构已就绪 |

| | **Typeless** | **Xisper** |
|--|:---:|:---:|
| **总分（macOS + 免提约束下）** | **44 / 55** | **37 / 55** |

---

## 13. 结论与建议

### 13.1 总体结论

**在 macOS + 免提模式约束下，Typeless 的实现整体更优雅**，体现在三个核心优势：

1. **按下即响应**（Typeless 按下 FN 立即开始初始化；Xisper 需等 FN 松开）
2. **keyup 真正忽略**（Typeless XState 状态定义层面忽略；Xisper 走完全链路才忽略）
3. **更简单的原生桥接**（koffi + 预编译 dylib；无需 Rust 编译）

### 13.2 Xisper 的架构价值

Xisper 的复杂设计是对**未来能力的预置**，当这些能力激活时架构合理性立即显现：

| 未来能力 | Xisper 现状 |
|---------|-----------|
| **长按模式** | ✅ ShortcutMatcher 已有 commitUp，录音 Action 响应 keyup 即可 |
| **Windows/Linux** | ✅ uiohook-napi 跨平台，Layer 2 无需改动 |
| **复杂组合键** | ✅ 精确 9 位修饰键匹配，支持左右区分 |
| **多 Action / 多快捷键** | ✅ HotkeySystem 路由表，任意多组快捷键 |
| **Capture 录制** | ✅ 完善，HID 层完全透明让用户录制任意键 |

### 13.3 对 Xisper 的具体优化建议

#### ① FN 按下即触发（高优先级，仅 5 行改动）

**当前问题**：同时配置 FN 和 FN+Space 时，FN 切换录音需等松开才触发。

```typescript
// matcher.ts: handleFnPress() 修改方案
handleFnPress(): void {
  this.fnPressed = true
  this.fnComboUsed = false
  this.modifiers.fn = true

  if (!this.fnOnlyShortcut) return

  // 当前：!this.hasFnComboShortcuts 才立即触发（有 FN+key 时等松开）
  // 建议：改为始终立即触发 commitDown，与 Typeless 行为对齐
  this.commitDown('FN')   // ← 去掉 hasFnComboShortcuts 判断
}

// handleFnRelease() 中移除"松开时补触发纯 FN"逻辑（已经在按下时触发了）
handleFnRelease(): void {
  this.fnPressed = false
  this.modifiers.fn = false
  this.fnComboUsed = false
  // 仅结束 FN+key 组合快捷键（如果正在进行）
  if (this.activeShortcut) { ... commitUp }
  // ← 不再在松开时触发纯 FN
}
```

**效果**：FN 按下时立即切换录音，与 Typeless 的用户体验对齐。

**副作用注意**：若同时配置了 FN+Space，按 FN+Space 时会在 FN 按下时先触发一次 FN（commitDown('FN')），再在 Space 按下时触发 FN+Space。需要确认 FN+Space 场景是否可接受这个"先触发 FN"的行为。

#### ② 录音时动态加入 Escape（中优先级）

Typeless 在录音时动态向 Swift 监听加入 `["Escape"]`，用户可按 Escape 取消录音。

Xisper 可类似实现：进入录音状态时，向快捷键系统动态注册 Escape 快捷键（临时的，非持久化的），录音结束后移除。

#### ③ MIN_PRESS_DURATION 免提优化（低优先级）

让录音 Action 在免提模式下向 Matcher 发信号"不需要 keyup"，或在 Matcher 中增加"免提模式"标志跳过 MIN_PRESS_DURATION 校验。改动较大，收益有限，可暂时搁置。

### 13.4 一句话总结

| | 一句话 |
|--|------|
| **Typeless** | State-based Key-State 模型 + XState 状态机：直接、精准，按下即响应；代价是引入 LONG_PRESS_MS 定时器区分 tap/hold（免提下轻微冗余） |
| **Xisper** | Edge-based Event 模型 + 自定义 TypeScript 状态机：精确、可扩展，为长按和跨平台预置能力；代价是当前仅免提时有明显冗余，FN 触发有延迟 |
| **建议** | 优先修复 FN 按下即触发（5行改动）；其余现有架构作为长按/跨平台的基础保留 |
