import SwiftUI
import AppKit

// MARK: - Semantic Colors (hand-authored, extends auto-generated DesignTokens)

extension Color {
    /// Foreground on vivid primary/accent backgrounds — always near-white for contrast.
    static let onPrimary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua]) == .darkAqua
            ? NSColor(red: 240/255, green: 246/255, blue: 247/255, alpha: 1)
            : NSColor.white
    })

    /// Modal backdrop overlay.
    static let scrim = Color(nsColor: NSColor(white: 0, alpha: 0.25))

    /// Enterprise tier badge.
    static let enterprise = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua]) == .darkAqua
            ? NSColor(red: 140/255, green: 110/255, blue: 210/255, alpha: 1)
            : NSColor(red: 108/255, green: 77/255, blue: 186/255, alpha: 1)
    })
}
