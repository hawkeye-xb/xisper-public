import Foundation

// MARK: - Key Name Maps (aligned with Electron KEYCODE_TO_NAME + constants.ts)

enum ShortcutKey {

    /// Carbon VKC → canonical key name (same as Electron's KEYCODE_TO_NAME).
    static let keycodeToName: [Int32: String] = [
        // Modifier keys (reported by flagsChanged)
        0x37: "LeftMeta",     0x36: "RightMeta",
        0x38: "LeftShift",    0x3C: "RightShift",
        0x3A: "LeftAlt",      0x3D: "RightAlt",
        0x3B: "LeftControl",  0x3E: "RightControl",
        // Letters
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B",
        0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x28: "K",
        0x2D: "N", 0x2E: "M",
        // Numbers
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
        0x16: "6", 0x17: "5", 0x19: "9", 0x1A: "7", 0x1C: "8", 0x1D: "0",
        // Punctuation / symbols
        0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";",
        0x2B: ",", 0x2C: "/", 0x2F: ".", 0x32: "`",
        // Whitespace / control
        0x31: "Space", 0x30: "Tab",
        0x24: "Enter", 0x33: "Backspace", 0x35: "Escape",
        // Navigation
        0x75: "Delete", 0x73: "Home", 0x77: "End",
        0x74: "PageUp", 0x79: "PageDown",
        0x7E: "Up", 0x7D: "Down", 0x7B: "Left", 0x7C: "Right",
        // Function keys
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// Keys treated as modifiers during capture (same as Electron UI_MODIFIER_KEYS).
    static let modifierKeys: Set<String> = [
        "FN",
        "LeftShift", "RightShift",
        "LeftControl", "RightControl",
        "LeftAlt", "RightAlt",
        "LeftMeta", "RightMeta",
    ]

    /// Display symbols (same as web KEY_TO_SYMBOL_MAP).
    static let keyToSymbol: [String: String] = [
        "FN": "Fn",
        "LeftMeta": "⌘L", "RightMeta": "⌘R",
        "LeftShift": "⇧L", "RightShift": "⇧R",
        "LeftControl": "⌃L", "RightControl": "⌃R",
        "LeftAlt": "⌥L", "RightAlt": "⌥R",
        "Backspace": "⌫", "Delete": "⌦",
        "Enter": "↩", "Escape": "⎋",
        "Tab": "⇥", "Space": "␣",
        "Up": "↑", "Down": "↓", "Left": "←", "Right": "→",
    ]

    static func formatKeySymbol(_ key: String) -> String {
        keyToSymbol[key] ?? key.uppercased()
    }

    static func isModifier(_ key: String) -> Bool {
        modifierKeys.contains(key)
    }

    static func keyName(for keyCode: Int32) -> String? {
        keycodeToName[keyCode]
    }

    static func keyCode(for name: String) -> Int32? {
        keycodeToName.first(where: { $0.value == name })?.key
    }
}

// MARK: - Shortcut Target (set-based matching)

struct ShortcutTarget {
    let actionId: String
    let normalized: String   // original string, e.g. "FN+T"
    let keys: Set<String>    // lowercased key names, e.g. {"fn", "t"}
}

// MARK: - Shortcut Target Parser

enum ShortcutTargetParser {

    static func parse(actionId: String, shortcut: String) -> ShortcutTarget? {
        let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "+").map { String($0).lowercased() }
        guard !parts.isEmpty else { return nil }
        return ShortcutTarget(actionId: actionId, normalized: trimmed, keys: Set(parts))
    }
}

// MARK: - Shortcut Validator (mirrors Electron shortcut/validator.ts)

enum ShortcutValidator {

    static let maxKeyCombination = 3

    private static let standaloneAllowedKeys: Set<String> = {
        var s = Set<String>()
        // Navigation
        for k in ["Up", "Down", "Left", "Right", "PageUp", "PageDown", "Home", "End"] { s.insert(k) }
        // Delete
        s.insert("Delete")
        // Symbols
        for k in ["[", "]", ";", "'", ".", "/", ","] { s.insert(k) }
        // Right-side modifiers
        for k in ["RightShift", "RightControl", "RightAlt", "RightMeta"] { s.insert(k) }
        return s
    }()

    private static let standaloneForbiddenKeys: Set<String> = {
        var s = Set<String>()
        for k in ["F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12"] { s.insert(k) }
        for k in ["Backspace", "Escape", "Tab", "Enter"] { s.insert(k) }
        for k in ["LeftShift","LeftControl","LeftAlt","LeftMeta"] { s.insert(k) }
        return s
    }()

    private static let requiresModifierKeys: Set<String> = {
        var s = Set<String>()
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { s.insert(String(c)) }
        for n in 0...9 { s.insert(String(n)) }
        for k in ["`", "Space"] { s.insert(k) }
        return s
    }()

    /// Returns nil if valid, or an error message string.
    static func validate(_ shortcut: String) -> String? {
        let trimmed = shortcut.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Shortcut cannot be empty" }
        if trimmed == "FN" { return nil }

        let parts = trimmed.split(separator: "+").map(String.init)
        var modifiers: [String] = []
        var mainKeys: [String] = []

        for p in parts {
            if ShortcutKey.isModifier(p) { modifiers.append(p) }
            else { mainKeys.append(p) }
        }

        // Standalone modifier (any side)
        if mainKeys.isEmpty && modifiers.count == 1 { return nil }

        // Multi-modifier combo (e.g. FN+LeftShift, LeftMeta+LeftShift)
        if mainKeys.isEmpty && modifiers.count >= 2 { return nil }
        if parts.count > maxKeyCombination { return "Max \(maxKeyCombination) keys" }

        // Single key without modifiers
        if mainKeys.count == 1 && modifiers.isEmpty {
            let key = mainKeys[0]
            if standaloneForbiddenKeys.contains(key) { return "This key is reserved by the system" }
            if requiresModifierKeys.contains(key) { return "This key must be combined with a modifier" }
            if !standaloneAllowedKeys.contains(key) { return "This key must be combined with a modifier" }
        }

        // Verify all main keys are resolvable
        for key in mainKeys {
            if ShortcutKey.keyCode(for: key) == nil { return "Unsupported key: \(key)" }
        }

        return nil
    }
}

// MARK: - Shortcut Display Helpers

/// Parse a shortcut string (e.g. "FN+T") into display symbols (e.g. ["Fn", "T"]).
func shortcutDisplayKeys(_ shortcut: String) -> [String] {
    guard !shortcut.isEmpty else { return [] }
    return shortcut.split(separator: "+").map { ShortcutKey.formatKeySymbol(String($0)) }
}

/// Build shortcut string from an array of UI key names (e.g. ["FN", "T"] → "FN+T").
func formatShortcut(_ keys: [String]) -> String {
    keys.joined(separator: "+")
}

// MARK: - ShortcutAction

struct ShortcutAction: Identifiable, Codable {
    let id: String
    var shortcuts: [String]
    let defaultShortcuts: [String]

    var primaryShortcut: String { shortcuts.first ?? "" }
    
    var name: String {
        switch id {
        case "dictation":
            return NSLocalizedString("Dictation", comment: "")
        case "translate":
            return NSLocalizedString("Translate", comment: "")
        default:
            return id
        }
    }
    
    var description: String {
        switch id {
        case "dictation":
            return NSLocalizedString("Global shortcut to start/stop", comment: "")
        case "translate":
            return NSLocalizedString("Press to start translation", comment: "")
        default:
            return ""
        }
    }
}

// MARK: - ShortcutStore

@Observable
final class ShortcutStore {

    static let shared = ShortcutStore()

    private(set) var actions: [ShortcutAction] = []

    /// Environment-specific UserDefaults
    private var defaults: UserDefaults {
        UserDefaults(suiteName: AppEnvironment.defaultsSuiteName) ?? .standard
    }
    private let storageKey = "xisper.shortcutActions.v2"

    private init() { load() }

    func updateShortcuts(actionId: String, shortcuts: [String]) {
        guard let idx = actions.firstIndex(where: { $0.id == actionId }) else { return }
        actions[idx].shortcuts = shortcuts
        save()
    }

    func resetToDefault(actionId: String) {
        guard let idx = actions.firstIndex(where: { $0.id == actionId }) else { return }
        actions[idx].shortcuts = actions[idx].defaultShortcuts
        save()
    }

    /// Check if a shortcut string is already used by another action.
    func conflictingAction(for shortcut: String, excluding actionId: String) -> String? {
        for action in actions where action.id != actionId {
            if action.shortcuts.contains(shortcut) { return action.name }
        }
        return nil
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        let defaultActions: [ShortcutAction] = [
            .init(id: "dictation",
                  shortcuts: ["FN"], defaultShortcuts: ["FN"]),
            .init(id: "translate",
                  shortcuts: ["FN+T"], defaultShortcuts: ["FN+T"]),
        ]

        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([ShortcutAction].self, from: data)
        else {
            actions = defaultActions
            return
        }

        var merged: [ShortcutAction] = []
        for def in defaultActions {
            if let saved = stored.first(where: { $0.id == def.id }) {
                merged.append(saved)
            } else {
                merged.append(def)
            }
        }
        actions = merged
    }
}
