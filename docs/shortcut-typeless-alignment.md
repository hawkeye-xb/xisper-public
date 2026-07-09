# Xisper × Typeless 快捷键系统对齐方案

> 目标：让 Xisper mac-desktop 的快捷键交互体验与 Typeless 完全一致，
> 同时利用原生 Swift 的优势（无 FFI 开销、直接系统 API 调用）做得更好。

---

## 一、核心概念解释

### 1. 键盘布局（Keyboard Layout）是什么？

macOS 支持多种键盘布局（输入法）：QWERTY（美式）、AZERTY（法式）、QWERTZ（德式）、日文、中文拼音等。

**同一个物理按键，在不同布局下对应不同字符：**

| 物理位置（keyCode） | QWERTY (美式) | AZERTY (法式) | QWERTZ (德式) |
|---|---|---|---|
| 0x0C | Q | A | Q |
| 0x00 | A | Q | A |
| 0x06 | Z | W | Y |
| 0x2C | / | ! | - |

CGEvent 给的是 **keyCode**（物理位置），不是字符。

**Typeless 的做法：**
- `keyName`：通过 `TISCopyCurrentKeyboardInputSource` + `kTISPropertyUnicodeKeyLayoutData` 查询当前键盘布局，把 keyCode 翻译成**当前布局的字符名**。法语布局下 keyCode 0x0C → "A"。
- `enKeyName`：无论当前什么布局，始终按 QWERTY 映射。keyCode 0x0C → 永远是 "Q"。
- `qwertyFallbackMap`：当 TIS 查不到当前布局的映射时，用 QWERTY 兜底。

**匹配时：先用 keyName 匹配，匹配不上再用 enKeyName 匹配。**

**举例：**
用户在法语布局下设置快捷键 "Fn+A"（按的是物理位置 0x0C）。切到英语布局后，同一物理键变成 "Q"。此时 keyName="Q" 匹配不上 "A"，但 enKeyName="Q" 也匹配不上 "A"——**快捷键跟随字符名，不跟随物理位置**。

> **对 Xisper 的影响**：modifier 键（Fn/Shift/Cmd/Ctrl/Alt）的名字在任何布局下都一样。Typeless 的典型快捷键（Fn、Fn+Space、Fn+LeftShift）不受键盘布局影响。布局 fallback 只对字母/符号键有意义，优先级中等。

**Xisper 当前：** 固定 keyCode → name 映射（`ShortcutKey.keycodeToName`），等同于只用 QWERTY 英文名。不感知当前键盘布局。

### 2. 键状态追踪（Key State Tracking）追踪什么？

**Typeless：追踪当前按下的"所有键"**

```
时刻1: 用户按下 LeftCmd       → pressingKeys = [{LeftCmd}]
时刻2: 用户按下 LeftShift     → pressingKeys = [{LeftCmd}, {LeftShift}]
时刻3: 用户按下 V             → pressingKeys = [{LeftCmd}, {LeftShift}, {V}]
时刻4: 用户松开 V             → pressingKeys = [{LeftCmd}, {LeftShift}]
时刻5: 用户松开 LeftShift     → pressingKeys = [{LeftCmd}]
时刻6: 用户松开 LeftCmd       → pressingKeys = []
```

每个键的信息：`{keyCode: 55, keyName: "LeftCmd", enKeyName: "LeftCmd"}`

每次状态变化都发送**完整集合**，不是增量事件。

**Xisper 当前：只追踪 9 个 modifier flag + FN 状态**

```swift
struct ShortcutModifierFlags {
    var fn, shiftLeft, shiftRight, controlLeft, controlRight,
        altLeft, altRight, metaLeft, metaRight: Bool
}
```

**不追踪**普通键（字母、数字、Space 等）是否按下。只在收到 keyDown/keyUp 事件时逐个匹配。

**差异带来的问题：**

| 快捷键 | Typeless | Xisper 当前 |
|---|---|---|
| `Fn` | ✅ pressingKeys={Fn}, target={Fn}, 匹配 | ✅ fnDown → commitDown("FN") |
| `Fn+Space` | ✅ pressingKeys={Fn,Space}, target={Fn,Space}, 匹配 | ✅ fnPressed + keyDown(Space) → Path 1 |
| `Fn+LeftShift` | ✅ pressingKeys={Fn,LeftShift}, target={Fn,LeftShift}, 匹配 | ✅ FN+modifier combo → Path 1 |
| **`LeftCmd+LeftShift`** | ✅ pressingKeys={LeftCmd,LeftShift}, target={LeftCmd,LeftShift}, 匹配 | ❌ **两个都是 modifier，mainKeyCode=nil，parser 返回 nil** |
| **`LeftShift`** (单独) | ✅ pressingKeys={LeftShift}, target={LeftShift}, 匹配 | ❌ **左侧 modifier 单独使用被 validator 禁止** |
| `RightShift` (单独) | ✅ | ✅ standaloneModifierKeycodes |
| `LeftCmd+V` | ✅ pressingKeys={LeftCmd,V}, target={LeftCmd,V}, 匹配 | ✅ Path 3: modifier+key |

### 3. Fn 检测方式对比

**Typeless：CGEventTap + 5ms watcher timer 双重机制**
- CGEventTap 的 flagsChanged 事件可以检测 Fn 状态变化
- 另外有一个 5ms 周期的 NSTimer 轮询 CGEventFlags，作为补充
- 双保险：即使 CGEventTap 被系统暂时禁用（tapDisabledByTimeout），watcher 仍在工作

**Xisper：纯 CGEventTap flagsChanged**
- 只依赖 CGEventTap 的 flagsChanged 事件
- 如果 tap 被系统禁用，会在 dispatchEvent 中重新 enable
- 没有额外的轮询机制

**哪个更好？**
- 正常情况下效果相同。两者都能可靠检测 Fn 状态。
- Typeless 的 watcher timer 是**防御性设计**：CGEventTap 有极端情况会被系统临时禁用（CPU 占用过高时），timer 提供了降级路径。
- 但 5ms timer 有额外 CPU 开销（每秒 200 次轮询），虽然很小。
- **建议**：保持我们当前方式，加上 tap re-enable 已经足够。如果实测发现丢事件，再加 timer。

### 4. 匹配模型对比

**Typeless：集合匹配（Set Matching）**
```
目标: {"fn", "leftshift"}
按下: {"fn", "leftshift"}
规则: 目标 ⊆ 按下 AND 按下.count == 目标.count → 精确匹配
```

**Xisper：事件序列匹配（Event-Sequence Matching, 3-path）**
```
Path 1: FN 按下 + keyDown(目标键) + modifier flags 匹配 → FN combo
Path 2: keyDown(目标键) + 无 modifier → standalone
Path 3: modifier flags 匹配 + keyDown(目标键) → modifier+key combo
```

**集合匹配的优势：**
1. **任意组合都自然支持**：两个 modifier、三个 modifier、modifier+多个普通键……不需要特殊 path
2. **逻辑简单**：一个算法覆盖所有场景
3. **不需要 "mainKeyCode" 概念**：不用区分哪个键是 "主键"、哪些是 "修饰键"
4. **精确匹配防误触**：按下多余的键会立刻失效（pressed.count ≠ target.count）

**事件序列匹配的优势：**
1. **即时响应**：keyDown 一到就触发，不需要等待"稳定状态"
2. **FN tap vs hold 可区分**：FN 松开时才判断是 tap 还是 combo

**建议**：切换到集合匹配。3-path 的复杂性在多 modifier 组合场景下是负担。

---

## 二、逐项差异清单

| # | 维度 | Typeless 行为 | Xisper 当前行为 | 需要改？ | 优先级 |
|---|---|---|---|---|---|
| 1 | 匹配模型 | 集合匹配 (pressed SET == target SET) | 3-path 事件序列匹配 | **是** | P0 |
| 2 | 键状态追踪 | 追踪所有按下的键（modifier+普通键） | 只追踪 9 个 modifier flag | **是** | P0 |
| 3 | 双 modifier 组合 | ✅ 支持 `LeftCmd+LeftShift` | ❌ parser 返回 nil | **是** | P0 |
| 4 | 左侧 modifier 单独使用 | ✅ 支持 `LeftShift` 单独 | ❌ validator 禁止 | **是** | P1 |
| 5 | 事件消耗 | ShortcutDetector 在原生层决定消耗 | HotkeySystem 在 Swift 层决定，KeyboardMonitor 按配置消耗 | 微调 | P1 |
| 6 | Globe/emoji 抑制 | 纯 CGEventTap 消耗 | CGEventTap + TIS 私有 API | 保持我们的，更稳 | - |
| 7 | Key name 命名 | LeftCmd/LeftOption/LeftCtrl | LeftMeta/LeftAlt/LeftControl | 可选对齐 | P2 |
| 8 | 键盘布局感知 | TIS API 获取当前布局字符名 + QWERTY fallback | 固定 keyCode→name | 后续增强 | P3 |
| 9 | Fn 检测 | CGEventTap + 5ms watcher timer | 纯 CGEventTap + re-enable | 当前够用 | P3 |
| 10 | 释放检测 | 集合变化自动检测 | keyUp 事件 + fnUp 事件 | 随 #1 改 | P0 |

---

## 三、实现方案

### Phase 1: 集合匹配引擎（P0 — 核心改动）

#### 改动文件 1: `KeyboardMonitor.swift`

**当前**：回调签名 `(KeyEventType, Int32, UInt32) -> Void`（逐事件）

**改为**：保留逐事件回调（用于消耗判断），新增**集合状态回调**

```swift
struct PressedKey: Equatable, Hashable {
    let keyCode: Int32
    let keyName: String
}

/// 新增：状态变化回调，每次按键状态改变时发送当前所有按下的键
typealias StateCallback = ([PressedKey]) -> Void
```

在 `dispatchEvent` 中维护一个 `pressingKeys: [Int32: PressedKey]` 字典：

```swift
// keyDown/flagsChanged(press) → pressingKeys[keyCode] = PressedKey(...)
// keyUp/flagsChanged(release) → pressingKeys.removeValue(forKey: keyCode)
// Fn down → pressingKeys[FN_VIRTUAL_CODE] = PressedKey(keyCode: -1, keyName: "Fn")
// Fn up → pressingKeys.removeValue(forKey: FN_VIRTUAL_CODE)
// 每次变化后 → stateCallback(Array(pressingKeys.values))
```

**事件消耗逻辑**保持不变：由配置的 `interceptFnCodes` / `interceptCombos` 决定。

#### 改动文件 2: `ShortcutConfig.swift`

**删除**：`ParsedShortcut`、`ShortcutParser`（3-path 概念不再需要）
**删除**：`ShortcutModifierFlags`（集合匹配不需要独立 modifier flag 追踪）

**新增**：

```swift
/// 一个快捷键 = 一个键名集合
struct ShortcutTarget {
    let actionId: String
    let normalized: String           // 原始字符串 "Fn+LeftShift"
    let keys: Set<String>            // {"fn", "leftshift"} (lowercased)
}
```

**解析**直接用 split：

```swift
static func parseTarget(actionId: String, shortcut: String) -> ShortcutTarget? {
    let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let keys = Set(trimmed.split(separator: "+").map { String($0).lowercased() })
    return ShortcutTarget(actionId: actionId, normalized: trimmed, keys: keys)
}
```

**Validator 放宽**：允许左侧 modifier 单独使用、允许双 modifier 组合。

#### 改动文件 3: `HotkeySystem.swift`

**删除**：3-path `matchShortcut` 方法
**删除**：`fnPressed`、`fnComboUsed`、`modifiers` 状态追踪
**保留**：`activeShortcut`、debounce、action dispatch

**新增**：集合匹配逻辑

```swift
/// KeyboardMonitor 的 stateCallback 调用此方法
@MainActor
private func handleStateChange(pressingKeys: [PressedKey]) {
    let pressedSet = Set(pressingKeys.map { $0.keyName.lowercased() })

    // 检查是否精确匹配某个快捷键
    var matched: ShortcutTarget?
    for target in targets {
        if pressedSet == target.keys {
            matched = target
            break
        }
    }

    if let matched {
        // 新激活
        if activeShortcut == nil {
            commitDown(matched)
        }
    } else {
        // 释放（任何一个键松开导致集合不匹配）
        if let active = activeShortcut {
            commitUp(active)
        }
    }
}
```

**关键行为变化**：
- **按住触发 (press-and-hold)**：集合匹配 → `commitDown` → 开始录音
- **释放停止**：集合不再匹配 → `commitUp` → 停止录音
- **精确匹配**：按下额外的键 → 集合不匹配 → 自动停止
- **无需 FN tap vs hold 区分**：按下即触发，不等松开

### Phase 2: 消耗逻辑对齐（P1）

当前 `KeyboardMonitor` 的消耗由预配置的 `interceptFnCodes` + `interceptCombos` 决定。

改为：**由 HotkeySystem 根据 targets 生成消耗规则**

```swift
/// 从 targets 自动计算需要消耗的事件
private func computeInterceptConfig() -> InterceptConfig {
    var interceptFn = false
    var fnKeyCodes: Set<Int32> = []
    var combos: [(modifierMask: UInt32, keycode: Int32)] = []

    for target in targets {
        if target.keys.contains("fn") {
            interceptFn = true
            // Fn + 其他键的 keyCode 加入 fnKeyCodes
            for key in target.keys where key != "fn" {
                if let code = ShortcutKey.keyCode(for: key) {
                    fnKeyCodes.insert(code)
                }
            }
        }
        // 非 Fn 的 modifier+key 组合加入 combos
        // ...
    }
    return InterceptConfig(interceptFn: interceptFn, fnKeyCodes: fnKeyCodes, combos: combos)
}
```

### Phase 3: 键盘布局感知（P3 — 后续增强）

**新增 `KeyboardLayoutHelper`**：

```swift
import Carbon.HIToolbox

enum KeyboardLayoutHelper {
    /// 获取当前键盘布局下 keyCode 对应的字符名
    static func localKeyName(for keyCode: Int32) -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = unsafeBitCast(layoutData, to: CFData.self) as Data
        // UCKeyTranslate to get character...
        // Return the character string
    }

    /// QWERTY 英文名（固定映射，当前 ShortcutKey.keycodeToName）
    static func englishKeyName(for keyCode: Int32) -> String? {
        ShortcutKey.keycodeToName[keyCode]
    }
}
```

---

## 四、Key Name 对齐映射

如果要让从 Typeless 迁移的用户设置无缝兼容：

| Typeless 名 | Xisper 当前名 | 建议统一为 | keyCode |
|---|---|---|---|
| LeftCmd | LeftMeta | **LeftCmd** | 0x37 |
| RightCmd | RightMeta | **RightCmd** | 0x36 |
| LeftOption | LeftAlt | **LeftOption** | 0x3A |
| RightOption | RightAlt | **RightOption** | 0x3D |
| LeftCtrl | LeftControl | **LeftCtrl** | 0x3B |
| RightCtrl | RightControl | **RightCtrl** | 0x3E |
| LeftShift | LeftShift | LeftShift | 0x38 |
| RightShift | RightShift | RightShift | 0x3C |
| Fn | FN | **Fn** | flags |
| CapsLock | (无) | **CapsLock** | 0x39 |
| Tab | Tab | Tab | 0x30 |
| Space | Space | Space | 0x31 |
| Enter | Enter | Enter | 0x24 |
| Escape | Escape | Escape | 0x35 |
| Delete | Delete | Delete | 0x75 |
| Backspace | Backspace | Backspace | 0x33 |

> 注：改名是 P2，不阻塞功能。内部用 keyCode 匹配，名字只影响存储和显示。

---

## 五、Typeless 默认快捷键（供参考）

| 功能 | Typeless 默认 | Xisper 当前默认 |
|---|---|---|
| Push to Talk（按住说话） | `Fn` | `FN` |
| Hands-free Mode（免提） | `Fn+Space` | 无 |
| Translation Mode（翻译） | `Fn+LeftShift` | `FN+T` |
| Paste Last Transcript | `LeftCtrl+LeftCmd+V` | 无 |

---

## 六、改动量评估

| 文件 | 改动程度 | 说明 |
|---|---|---|
| `ShortcutConfig.swift` | **重写** | 删除 ParsedShortcut/Parser/ModifierFlags，换为 ShortcutTarget + set 解析 |
| `HotkeySystem.swift` | **重写匹配逻辑** | 删除 3-path matcher，换为 set matching；保留 action dispatch |
| `KeyboardMonitor.swift` | **增量** | 新增 pressingKeys 字典 + stateCallback；原有消耗逻辑保留 |
| `SettingsView.swift` (Shortcuts) | **适配** | 验证逻辑放宽（允许左 modifier 单独、双 modifier 组合） |
| `ShortcutStore` | **微调** | 默认值对齐、key name 迁移 |

预估工作量：~400 行新增/修改，~200 行删除。不影响录音、ASR、UI 等其他模块。
