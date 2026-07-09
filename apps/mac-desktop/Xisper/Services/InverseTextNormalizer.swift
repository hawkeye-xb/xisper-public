/**
 * InverseTextNormalizer
 *
 * Client-side rule-based Inverse Text Normalization (ITN).
 * Converts Chinese spoken-form numbers to standard digit form.
 * Runs in RecordingCoordinator AFTER ASR and BEFORE optional LLM post-process.
 *
 * Rules applied in order (to avoid conflicts):
 *   1. 百分之五十     → 50%
 *   2. 二零二四年     → 2024年   (four individual digit chars before 年)
 *   3. 三月/十一日/三点半  (date/time with known unit suffix)
 *   4. 三百二十一     → 321      (compound numbers containing a unit char)
 *
 * Invariant: if the ASR server already emitted digits, these patterns will
 * not match (they target Chinese character forms only).
 */

import Foundation

enum InverseTextNormalizer {

    // MARK: - Public entry point

    static func normalize(_ text: String) -> String {
        var s = text
        s = normPercent(s)
        s = normYearDigits(s)
        s = normDateTimeUnits(s)
        s = normCompoundNumbers(s)
        return s
    }

    // MARK: - Rule 1: 百分之X → X%
    // e.g. 百分之五十 → 50%,  百分之八十五点六 → 85.6%

    private static func normPercent(_ text: String) -> String {
        let numPat = "[零一二三四五六七八九十百千万两点.\\d]+"
        return repl("百分之(\(numPat))", in: text) { groups in
            guard let val = parseAny(groups[0]) else { return nil }
            return fmt(val) + "%"
        }
    }

    // MARK: - Rule 2: 二零二四年 / 二〇二四年 → 2024年

    private static func normYearDigits(_ text: String) -> String {
        repl("([零〇一二三四五六七八九]{4})年", in: text) { groups in
            let ds = groups[0].compactMap { digit0($0) }
            guard ds.count == 4 else { return nil }
            return "\(ds[0]*1000 + ds[1]*100 + ds[2]*10 + ds[3])年"
        }
    }

    // MARK: - Rule 3: Date/time with unit suffix

    private static let unitRules: [(suffix: String, maxVal: Int)] = [
        ("月",  12), ("日",  31), ("号",  31),
        ("点",  24), ("时",  24),
        ("分钟", 60), ("分",  60), ("秒",  60),
    ]

    private static func normDateTimeUnits(_ text: String) -> String {
        var s = text
        let numPat = "[零一二三四五六七八九十两]+"
        for rule in unitRules {
            let escaped = NSRegularExpression.escapedPattern(for: rule.suffix)
            s = repl("(\(numPat))\(escaped)", in: s) { groups in
                guard let v = parseCompound(groups[0]),
                      v > 0, v <= rule.maxVal else { return nil }
                return "\(v)\(rule.suffix)"
            }
        }
        return s
    }

    // MARK: - Rule 4: Compound numbers  e.g. 三百二十一 → 321

    private static let numChars = "[零一二三四五六七八九十百千万亿两]"

    private static func normCompoundNumbers(_ text: String) -> String {
        // Match at least 2 consecutive Chinese number characters.
        // The transform then checks for a unit char (十百千万亿) to
        // avoid converting pure digit sequences (一二三) or single chars.
        return repl("(\(numChars)\(numChars)+)", in: text) { groups in
            let s = groups[0]
            guard s.contains(where: { "十百千万亿".contains($0) }) else { return nil }
            guard let v = parseCompound(s) else { return nil }
            return String(v)
        }
    }

    // MARK: - Regex helper

    /// Replace all matches of `pattern`. Capture groups → `groups` (or `[fullMatch]`).
    /// Return nil to keep the original match unchanged.
    private static func repl(
        _ pattern: String,
        in text: String,
        transform: ([String]) -> String?
    ) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = ""
        var tail = text.startIndex
        for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let fr = Range(m.range, in: text) else { continue }
            out += text[tail..<fr.lowerBound]
            var groups = [String]()
            for i in 1..<m.numberOfRanges {
                if let r = Range(m.range(at: i), in: text) { groups.append(String(text[r])) }
            }
            if groups.isEmpty { groups.append(String(text[fr])) }
            out += transform(groups) ?? String(text[fr])
            tail = fr.upperBound
        }
        out += text[tail...]
        return out
    }

    // MARK: - Chinese number parser

    /// Parse a Chinese compound number string → Int.
    /// Returns nil if the string is not a well-formed compound number.
    /// e.g. 三百二十一 → 321,  两万三千五百 → 23500,  十五 → 15
    static func parseCompound(_ s: String) -> Int? {
        let cs = Array(s)
        guard !cs.isEmpty else { return nil }
        return parseYi(cs)
    }

    private static func parseYi(_ cs: [Character]) -> Int? {
        guard let idx = cs.lastIndex(of: "亿") else { return parseWan(cs) }
        let before = Array(cs.prefix(idx))
        let after  = Array(cs.dropFirst(idx + 1))
        let hi: Int
        if before.isEmpty        { hi = 1 }
        else if let v = parseWan(before) { hi = v }
        else                      { return nil }
        let lo = after.isEmpty ? 0 : (parseYi(after) ?? 0)
        return hi * 100_000_000 + lo
    }

    private static func parseWan(_ cs: [Character]) -> Int? {
        guard let idx = cs.lastIndex(of: "万") else { return parseLT10k(cs) }
        let before = Array(cs.prefix(idx))
        let after  = Array(cs.dropFirst(idx + 1))
        let hi: Int
        if before.isEmpty         { hi = 1 }
        else if let v = parseLT10k(before) { hi = v }
        else                       { return nil }
        let lo = after.isEmpty ? 0 : (parseLT10k(after) ?? 0)
        return hi * 10_000 + lo
    }

    /// Parse number in the range 0 – 9999.
    private static func parseLT10k(_ cs: [Character]) -> Int? {
        guard !cs.isEmpty else { return nil }
        var result  = 0
        var pending: Int? = nil
        var start   = 0

        // 十 at start → implicit leading 1 (十五 = 15, not 010+5)
        if cs[0] == "十" { result = 10; start = 1 }

        for i in start ..< cs.count {
            let c = cs[i]
            switch c {
            case "零", "〇":
                pending = 0
            case "一", "二", "两", "三", "四", "五", "六", "七", "八", "九":
                // Consecutive non-zero digits without a unit → not a compound number
                if let p = pending, p != 0 { return nil }
                pending = digitVal(c)
            case "十":
                result += (pending ?? 1) * 10;   pending = nil
            case "百":
                result += (pending ?? 1) * 100;  pending = nil
            case "千":
                result += (pending ?? 1) * 1000; pending = nil
            default:
                return nil  // Unexpected character
            }
        }
        if let d = pending, d > 0 { result += d }
        return result
    }

    // MARK: - Helpers

    /// Parse a value that might be Chinese (三百) or Arabic (300), with optional
    /// decimal point using 点 (八十五点六 → 85.6).
    private static func parseAny(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        if let di = s.firstIndex(of: "点") {
            let intStr  = String(s[..<di])
            let fracStr = String(s[s.index(after: di)...])
            guard let iv = parseCompound(intStr) else { return nil }
            let fracDigits = fracStr.compactMap { digit0($0) }
            guard !fracDigits.isEmpty else { return Double(iv) }
            let frac = Double("0." + fracDigits.map { String($0) }.joined()) ?? 0
            return Double(iv) + frac
        }
        guard let v = parseCompound(s) else { return nil }
        return Double(v)
    }

    /// Map a single Chinese (or ASCII) digit character to its Int value.
    private static func digit0(_ c: Character) -> Int? {
        switch c {
        case "零", "〇", "0": return 0
        case "一", "1": return 1
        case "二", "2": return 2
        case "三", "3": return 3
        case "四", "4": return 4
        case "五", "5": return 5
        case "六", "6": return 6
        case "七", "7": return 7
        case "八", "8": return 8
        case "九", "9": return 9
        default: return nil
        }
    }

    /// Map a non-zero Chinese digit character to its Int value.
    private static func digitVal(_ c: Character) -> Int {
        switch c {
        case "一":       return 1
        case "二", "两": return 2
        case "三":       return 3
        case "四":       return 4
        case "五":       return 5
        case "六":       return 6
        case "七":       return 7
        case "八":       return 8
        case "九":       return 9
        default:         return 0
        }
    }

    /// Format a Double: emit Int string if whole, otherwise decimal string.
    private static func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }
}
