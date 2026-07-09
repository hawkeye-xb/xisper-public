import Foundation
import AppKit
import ApplicationServices

// MARK: - Memory management

/// Allocate a C string copy that the caller (Node.js via koffi) must free with xisper_freeString.
private func toCString(_ str: String) -> UnsafeMutablePointer<CChar>? {
    guard let data = str.data(using: .utf8) else { return nil }
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: data.count + 1)
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buf, count: data.count))
    buf[data.count] = 0
    return buf
}

@_cdecl("xisper_freeString")
public func freeString(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr = ptr else { return }
    ptr.deallocate()
}

// MARK: - Accessibility helpers

private func getFocusedApp() -> NSRunningApplication? {
    return NSWorkspace.shared.frontmostApplication
}

private func getAXFocusedElement() -> AXUIElement? {
    guard let app = getFocusedApp() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedElement: AnyObject?
    let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    guard result == .success else { return nil }
    return (focusedElement as! AXUIElement)
}

private func getAXAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success, let str = value as? String else { return nil }
    return str
}

// MARK: - Public API

@_cdecl("xisper_getFocusedAppInfo")
public func getFocusedAppInfo() -> UnsafeMutablePointer<CChar>? {
    guard let app = getFocusedApp() else { return nil }

    let name = app.localizedName ?? ""
    let bundleId = app.bundleIdentifier ?? ""
    let pid = app.processIdentifier

    let json: [String: Any] = ["name": name, "bundleId": bundleId, "pid": pid]
    guard let data = try? JSONSerialization.data(withJSONObject: json),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return toCString(str)
}

@_cdecl("xisper_getWindowTitle")
public func getWindowTitle() -> UnsafeMutablePointer<CChar>? {
    guard let app = getFocusedApp() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedWindow: AnyObject?
    let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    guard result == .success else { return nil }
    let window = focusedWindow as! AXUIElement
    guard let title = getAXAttribute(window, kAXTitleAttribute as String) else { return nil }
    return toCString(title)
}

@_cdecl("xisper_getSelectedText")
public func getSelectedText() -> UnsafeMutablePointer<CChar>? {
    guard let element = getAXFocusedElement() else { return nil }
    guard let text = getAXAttribute(element, kAXSelectedTextAttribute as String) else { return nil }
    if text.isEmpty { return nil }
    return toCString(text)
}

@_cdecl("xisper_getVisibleText")
public func getVisibleText() -> UnsafeMutablePointer<CChar>? {
    guard let element = getAXFocusedElement() else { return nil }
    guard let text = getAXAttribute(element, kAXValueAttribute as String) else { return nil }
    return toCString(text)
}

/// Attempt to extract the URL from the focused browser window.
/// Supports Safari (AXDocument on web area), Chrome/Arc/Edge (address bar AXValue).
@_cdecl("xisper_getWebInfo")
public func getWebInfo() -> UnsafeMutablePointer<CChar>? {
    guard let app = getFocusedApp() else { return nil }
    let bundleId = app.bundleIdentifier ?? ""

    var url: String? = nil
    var title: String? = nil

    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    // Get window title as page title fallback
    var focusedWindow: AnyObject?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success {
        title = getAXAttribute(focusedWindow as! AXUIElement, kAXTitleAttribute as String)
    }

    if bundleId == "com.apple.Safari" {
        // Safari: focused UI element's AXDocument attribute contains the URL
        if let element = getAXFocusedElement() {
            url = getAXAttribute(element, "AXDocument")
        }
        // Fallback: try the web area
        if url == nil, let window = focusedWindow {
            url = findSafariURL(window as! AXUIElement)
        }
    } else if isChromiumBrowser(bundleId) {
        url = findChromiumURL(axApp)
    }

    guard url != nil || title != nil else { return nil }

    var domain: String? = nil
    if let u = url, let components = URLComponents(string: u) {
        domain = components.host
    }

    let json: [String: Any?] = ["url": url, "domain": domain, "title": title]
    let filtered = json.compactMapValues { $0 }
    guard let data = try? JSONSerialization.data(withJSONObject: filtered),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return toCString(str)
}

// MARK: - AX tree traversal

private let skipRolesForText: Set<String> = [
    "AXWindow", "AXApplication", "AXMenuBar", "AXMenu",
    "AXToolbar", "AXImage", "AXSplitter", "AXScrollBar",
    "AXValueIndicator", "AXIncrementor",
]

private let containerRoles: Set<String> = [
    "AXScrollArea", "AXList", "AXTable", "AXOutline",
]

private func collectTextsFromAXTree(
    _ element: AXUIElement,
    _ texts: inout [String],
    _ seen: inout Set<String>,
    depth: Int,
    maxDepth: Int,
    maxItems: Int
) {
    if depth > maxDepth || texts.count >= maxItems { return }

    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""

    if !skipRolesForText.contains(roleStr) {
        let attrs = [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String]
        for attr in attrs {
            if let text = getAXAttribute(element, attr) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    texts.append(trimmed)
                    break
                }
            }
        }
    }

    if texts.count >= maxItems { return }

    // For scrollable containers, prefer AXVisibleChildren (only on-screen items)
    var children: AnyObject?
    if containerRoles.contains(roleStr) {
        if AXUIElementCopyAttributeValue(element, "AXVisibleChildren" as CFString, &children) != .success {
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        }
    } else {
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    }

    guard let childArray = children as? [AXUIElement] else { return }

    for child in childArray {
        collectTextsFromAXTree(child, &texts, &seen, depth: depth + 1, maxDepth: maxDepth, maxItems: maxItems)
        if texts.count >= maxItems { break }
    }
}

/// Debug: dump AX tree structure (role + text preview) for diagnosing what an app exposes
@_cdecl("xisper_dumpAXTree")
public func dumpAXTree() -> UnsafeMutablePointer<CChar>? {
    guard let app = getFocusedApp() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedWindow: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return nil }

    var lines: [String] = []
    dumpElement(focusedWindow as! AXUIElement, &lines, depth: 0, maxDepth: 12, maxLines: 300)
    let result = lines.joined(separator: "\n")
    return toCString(result)
}

private func dumpElement(_ element: AXUIElement, _ lines: inout [String], depth: Int, maxDepth: Int, maxLines: Int) {
    if depth > maxDepth || lines.count >= maxLines { return }

    let indent = String(repeating: "  ", count: depth)

    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? "?"

    var subrole: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    let subroleStr = subrole as? String

    var parts = ["\(indent)[\(roleStr)]"]
    if let sr = subroleStr { parts.append("(\(sr))") }

    let textAttrs: [(String, String)] = [
        ("V", kAXValueAttribute as String),
        ("T", kAXTitleAttribute as String),
        ("D", kAXDescriptionAttribute as String),
    ]
    for (label, attr) in textAttrs {
        if let text = getAXAttribute(element, attr), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = text.count > 60 ? String(text.prefix(60)) + "…" : text
            let escaped = preview.replacingOccurrences(of: "\n", with: "\\n")
            parts.append("\(label)=\"\(escaped)\"")
        }
    }

    lines.append(parts.joined(separator: " "))

    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let childArray = children as? [AXUIElement] else { return }

    for child in childArray {
        dumpElement(child, &lines, depth: depth + 1, maxDepth: maxDepth, maxLines: maxLines)
        if lines.count >= maxLines { break }
    }
}

@_cdecl("xisper_collectFullContext")
public func collectFullContext() -> UnsafeMutablePointer<CChar>? {
    guard let app = getFocusedApp() else { return nil }

    var result: [String: Any] = [:]

    // App info
    result["app"] = [
        "name": app.localizedName ?? "",
        "bundleId": app.bundleIdentifier ?? "",
        "pid": app.processIdentifier,
    ] as [String: Any]

    // Window title
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedWindow: AnyObject?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success {
        if let title = getAXAttribute(focusedWindow as! AXUIElement, kAXTitleAttribute as String) {
            result["windowTitle"] = title
        }
    }

    // Selected text from focused element
    if let element = getAXFocusedElement() {
        if let selected = getAXAttribute(element, kAXSelectedTextAttribute as String), !selected.isEmpty {
            result["selectedText"] = selected
        }
        if let value = getAXAttribute(element, kAXValueAttribute as String) {
            result["visibleText"] = value
        }
    }

    // Deep AX tree traversal — collect all visible text in the window
    if let window = focusedWindow {
        var texts: [String] = []
        var seen = Set<String>()
        collectTextsFromAXTree(window as! AXUIElement, &texts, &seen, depth: 0, maxDepth: 25, maxItems: 800)
        if !texts.isEmpty {
            result["windowText"] = texts.joined(separator: "\n")
        }
    }

    // Web info
    let bundleId = app.bundleIdentifier ?? ""
    if bundleId == "com.apple.Safari" || isChromiumBrowser(bundleId) {
        var webUrl: String? = nil
        if bundleId == "com.apple.Safari" {
            if let element = getAXFocusedElement() { webUrl = getAXAttribute(element, "AXDocument") }
            if webUrl == nil, let window = focusedWindow { webUrl = findSafariURL(window as! AXUIElement) }
        } else {
            webUrl = findChromiumURL(axApp)
        }
        if let u = webUrl {
            var web: [String: String] = ["url": u]
            if let components = URLComponents(string: u) { web["domain"] = components.host }
            if let title = result["windowTitle"] as? String { web["title"] = title }
            result["web"] = web
        }
    }

    result["collectedAt"] = Int(Date().timeIntervalSince1970 * 1000)

    guard let data = try? JSONSerialization.data(withJSONObject: result),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return toCString(str)
}

// MARK: - Browser helpers

private func isChromiumBrowser(_ bundleId: String) -> Bool {
    let chromiumBrowsers = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
    return chromiumBrowsers.contains(bundleId)
}

/// Chromium-based browsers expose the URL in the address bar AXTextField.
private func findChromiumURL(_ axApp: AXUIElement) -> String? {
    var focusedWindow: AnyObject?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else { return nil }
    return findURLTextField(focusedWindow as! AXUIElement, depth: 0, maxDepth: 8)
}

private func findURLTextField(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
    if depth > maxDepth { return nil }

    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""

    // Chromium address bar is an AXTextField with role description containing "address"
    if roleStr == "AXTextField" {
        var roleDesc: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDesc)
        let desc = (roleDesc as? String ?? "").lowercased()
        if desc.contains("address") || desc.contains("url") || desc.contains("location") {
            return getAXAttribute(element, kAXValueAttribute as String)
        }

        // Fallback: check if the value looks like a URL
        if let value = getAXAttribute(element, kAXValueAttribute as String),
           (value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains(".")) {
            var subrole: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == "AXSearchField" || desc.contains("search") {
                return value
            }
        }
    }

    // Recurse into children
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let childArray = children as? [AXUIElement] else { return nil }

    for child in childArray {
        if let url = findURLTextField(child, depth: depth + 1, maxDepth: maxDepth) {
            return url
        }
    }
    return nil
}

/// Safari: look for a web area element and read AXDocument.
private func findSafariURL(_ window: AXUIElement) -> String? {
    return findWebArea(window, depth: 0, maxDepth: 10)
}

private func findWebArea(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String? {
    if depth > maxDepth { return nil }
    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    if (role as? String) == "AXWebArea" {
        return getAXAttribute(element, "AXDocument")
    }
    var children: AnyObject?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let childArray = children as? [AXUIElement] else { return nil }
    for child in childArray {
        if let url = findWebArea(child, depth: depth + 1, maxDepth: maxDepth) {
            return url
        }
    }
    return nil
}
