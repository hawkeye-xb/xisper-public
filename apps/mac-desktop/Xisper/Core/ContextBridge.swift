/**
 * ContextBridge
 *
 * Native Swift port of packages/native-context/Sources/XisperContext/Context.swift.
 * Removes @_cdecl dylib exports and wraps AX/AppKit calls as a value type API.
 *
 * Used by InputWriter to query the frontmost application context.
 */

import AppKit
import ApplicationServices
import Foundation

// MARK: - Context types

struct FocusedAppInfo {
    let name:     String
    let bundleId: String
    let pid:      pid_t
}

struct WebInfo {
    let url:    String?
    let domain: String?
    let title:  String?
}

// MARK: - ContextBridge

enum ContextBridge {

    // MARK: - App info

    static func getFocusedAppInfo() -> FocusedAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusedAppInfo(
            name:     app.localizedName ?? "",
            bundleId: app.bundleIdentifier ?? "",
            pid:      app.processIdentifier
        )
    }

    // MARK: - Text accessors

    /// Selected text in the focused UI element (via AX kAXSelectedTextAttribute).
    static func getSelectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        let text = axString(element, kAXSelectedTextAttribute as String)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Full text value of the focused UI element (via AX kAXValueAttribute).
    static func getVisibleText() -> String? {
        guard let element = focusedElement() else { return nil }
        return axString(element, kAXValueAttribute as String)
    }

    /// Title of the focused window.
    static func getWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = axCopyValue(axApp, kAXFocusedWindowAttribute as CFString) else { return nil }
        return axString(window, kAXTitleAttribute as String)
    }

    // MARK: - Browser URL

    static func getWebInfo() -> WebInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleId = app.bundleIdentifier ?? ""
        let axApp    = AXUIElementCreateApplication(app.processIdentifier)

        let window = axCopyValue(axApp, kAXFocusedWindowAttribute as CFString)
        let title = window.flatMap { axString($0, kAXTitleAttribute as String) }

        var url: String?
        if bundleId == "com.apple.Safari" {
            if let el = focusedElement() { url = axString(el, "AXDocument") }
            if url == nil, let w = window { url = findSafariURL(w) }
        } else if isChromium(bundleId) {
            url = findChromiumURL(axApp)
        }

        guard url != nil || title != nil else { return nil }
        let domain = url.flatMap { URLComponents(string: $0)?.host }
        return WebInfo(url: url, domain: domain, title: title)
    }

    // MARK: - Private helpers

    /// Safe wrapper: copy an AX attribute value and return as AXUIElement, or nil.
    private static func axCopyValue(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              value != nil else { return nil }
        // AXUIElement is a CFTypeRef — when the API returns .success, the value is valid.
        return (value as! AXUIElement)
    }

    private static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return axCopyValue(axApp, kAXFocusedUIElementAttribute as CFString)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func isChromium(_ bundleId: String) -> Bool {
        ["com.google.Chrome", "com.google.Chrome.canary",
         "com.microsoft.edgemac", "company.thebrowser.Browser",
         "com.brave.Browser", "com.vivaldi.Vivaldi",
         "com.operasoftware.Opera"].contains(bundleId)
    }

    private static func findChromiumURL(_ axApp: AXUIElement) -> String? {
        guard let window = axCopyValue(axApp, kAXFocusedWindowAttribute as CFString) else { return nil }
        return findAddressBar(window, depth: 0)
    }

    private static func findAddressBar(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 9 else { return nil }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXTextField" {
            var desc: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &desc)
            let d = (desc as? String ?? "").lowercased()
            if d.contains("address") || d.contains("url") || d.contains("location") {
                return axString(element, kAXValueAttribute as String)
            }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return nil }
        for child in arr {
            if let url = findAddressBar(child, depth: depth + 1) { return url }
        }
        return nil
    }

    private static func findSafariURL(_ window: AXUIElement) -> String? {
        findWebArea(window, depth: 0)
    }

    private static func findWebArea(_ element: AXUIElement, depth: Int) -> String? {
        guard depth < 11 else { return nil }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXWebArea" { return axString(element, "AXDocument") }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return nil }
        for child in arr {
            if let url = findWebArea(child, depth: depth + 1) { return url }
        }
        return nil
    }
}
