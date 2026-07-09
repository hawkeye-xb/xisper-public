import SwiftUI

/// Small status popover shown when the user clicks the menu-bar icon.
struct TrayView: View {

    @State private var coordinator = RecordingCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {

            // ── Recording status ──
            HStack(spacing: 8) {
                statusDot
                statusLabel
                Spacer()
            }
            .padding(.horizontal, DesignSpacing.xxs)
            .padding(.vertical, DesignSpacing.xxxs)

            Divider()

            // ── Menu items ──
            VStack(spacing: 0) {
                TrayButton(NSLocalizedString("Open Xisper", comment: ""), icon: "arrow.up.forward.app") {
                    openAndNavigate(nil)
                }
                TrayButton(NSLocalizedString("History", comment: ""), icon: "clock") {
                    openAndNavigate(.history)
                }
                TrayButton(NSLocalizedString("Settings", comment: ""), icon: "gearshape") {
                    openAndNavigate(.settings)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // ── Updates & Quit ──
            VStack(spacing: 0) {
                TrayButton(NSLocalizedString("Check for Updates…", comment: ""), icon: "arrow.triangle.2.circlepath") {
                    XisperApp.updaterController.checkForUpdates(nil)
                }
                .foregroundStyle(.secondary)

                TrayButton(NSLocalizedString("Quit Xisper", comment: ""), icon: "xmark.circle") {
                    NSApplication.shared.terminate(nil)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignSpacing.xxxxs)
        }
        .frame(width: 220)
    }

    // MARK: - Helpers

    private func openAndNavigate(_ section: SidebarSection?) {
        AppDelegate.shared?.openMainWindow(forceActivate: true)
        if let section {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(name: .navigateToSection, object: section)
            }
        }
    }

    // MARK: - Status indicators

    @ViewBuilder
    private var statusDot: some View {
        switch coordinator.state {
        case .recording:
            ZStack {
                Circle().fill(Color.danger8.opacity(0.20)).frame(width: DesignSpacing.xxs, height: DesignSpacing.xxs)
                Circle().fill(Color.danger8).frame(width: DesignSpacing.icon_gap, height: DesignSpacing.icon_gap)
            }
        default:
            Circle().fill(Color.success8).frame(width: DesignSpacing.icon_gap, height: DesignSpacing.icon_gap)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.state {
        case .idle:
            Text(NSLocalizedString("Ready", comment: "")).font(.system(size: DesignFont.sm)).foregroundStyle(.secondary)
        case .recording:
            Text(NSLocalizedString("Recording…", comment: "")).font(.system(size: DesignFont.sm))
        case .finalizing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Finalizing…", comment: "")).font(.system(size: DesignFont.sm)).foregroundStyle(.secondary)
            }
        case .committing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Processing…", comment: "")).font(.system(size: DesignFont.sm)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tray button (menu-item style)

private struct TrayButton: View {
    let label:  String
    let icon:   String
    let action: () -> Void

    @State private var isHovered = false

    init(_ label: String, icon: String, action: @escaping () -> Void) {
        self.label  = label
        self.icon   = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Slightly more horizontal padding than the hover pill inset so the
                // leading SF Symbol does not sit flush against the highlight edge.
                .padding(.horizontal, DesignSpacing.xxxs + DesignSpacing.xxxxs)
                .padding(.vertical, DesignSpacing.icon_gap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.sm)
                .fill(isHovered ? Color.primary8.opacity(0.08) : Color.clear)
                .padding(.horizontal, DesignSpacing.icon_gap)
        )
        .animation(.fast, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
