/**
 * XisperUI.swift — Shared UI helpers and design system utilities
 *
 * Provides:
 *   - View.hoverBackground()    — applies subtle tinted background on hover
 *   - XisperMenuItemStyle       — ButtonStyle for sidebar/tray menu-item buttons
 */

import SwiftUI

// MARK: - Hover background

extension View {
    /// Applies a subtle tinted background fill when `isHovered` is true.
    func hoverBackground(
        isHovered: Bool,
        cornerRadius: CGFloat = DesignRadius.sm,
        color: Color = .primary8
    ) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isHovered ? color.opacity(0.08) : Color.clear)
        )
        .animation(.fast, value: isHovered)
    }
}

// MARK: - Menu-item button style (tray + sidebar custom buttons)

/// Full-width button with hover tint.
/// Mirrors web SideMenu item hover behaviour.
struct XisperMenuItemStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DesignSpacing.xxxs + DesignSpacing.xxxxs)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.sm)
                    .fill(
                        configuration.isPressed
                            ? Color.primary8.opacity(0.13)
                            : isHovered ? Color.primary8.opacity(0.07) : Color.clear
                    )
                    .padding(.horizontal, DesignSpacing.xxxxs)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .onHover { isHovered = $0 }
            .animation(.fast, value: isHovered)
            .animation(.responsive, value: configuration.isPressed)
    }
}

// MARK: - Tier badge helper

extension String {
    /// Design-system color for a usage tier label ("free", "pro", "enterprise").
    var tierBadgeColor: Color {
        switch self.lowercased() {
        case "pro":        return .primary8
        case "enterprise": return .enterprise
        default:           return .neutral7
        }
    }
}
