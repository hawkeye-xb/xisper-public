import SwiftUI

/// Home — 3-step quick guide + recording status (matches pen design nZfdn)
struct HomeView: View {

    @State private var coordinator = RecordingCoordinator.shared
    @State private var shortcutStore = ShortcutStore.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader()
            Divider()
            VStack(spacing: 32) {

                // ── Header: Wordmark + Subtitle ──
                VStack(spacing: DesignSpacing.xxxs) {
                    Image("XisperWordmark")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 36)
                        .foregroundStyle(Color.primary8)

                    Text(NSLocalizedString("Voice-first input, reimagined.", comment: ""))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.neutral9)
                }

                // ── 3-step guide ──
                VStack(spacing: DesignSpacing.xxs) {
                    StepCard(
                        icon: "keyboard",
                        title: String(format: NSLocalizedString("Hold %@", comment: ""), primaryShortcutDisplay),
                        description: NSLocalizedString("Press and hold the hotkey to activate voice input.", comment: "")
                    )
                    StepCard(
                        icon: "mic.fill",
                        title: NSLocalizedString("Speak naturally", comment: ""),
                        description: NSLocalizedString("Talk as you normally would — Xisper handles the rest.", comment: "")
                    )
                    StepCard(
                        icon: "list.clipboard.fill",
                        title: NSLocalizedString("Release to paste", comment: ""),
                        description: NSLocalizedString("Text is transcribed and pasted into your active app.", comment: "")
                    )
                }
                .frame(width: 420)

                Text(NSLocalizedString("You can change the hotkey in Settings.", comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.neutral7)

                // ── Recording status (only when active) ──
                if coordinator.state != .idle {
                    HStack(spacing: DesignSpacing.xxxs) {
                        statusDot
                        statusLabel
                    }
                    .padding(.horizontal, DesignSpacing.xxs)
                    .padding(.vertical, DesignSpacing.xxxs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.md)
                            .fill(Color.neutral2)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignRadius.md)
                                    .strokeBorder(Color.neutral3, lineWidth: 1)
                            )
                    )
                }

                if let err = coordinator.errorMessage {
                    Text(err)
                        .font(.system(size: DesignFont.sm))
                        .foregroundStyle(Color.danger8)
                        .padding(.horizontal, DesignSpacing.xxs)
                        .padding(.vertical, DesignSpacing.xxxs)
                        .background(
                            RoundedRectangle(cornerRadius: DesignRadius.md)
                                .fill(Color.danger8.opacity(0.1))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DesignSpacing.md)
        }
        .background(Color.neutral1)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusDot: some View {
        switch coordinator.state {
        case .recording:
            ZStack {
                Circle().fill(Color.danger8.opacity(0.20)).frame(width: 16, height: 16)
                Circle().fill(Color.danger8).frame(width: 8, height: 8)
            }
        default:
            Circle().fill(Color.neutral7).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .recording:
            Text(String(format: NSLocalizedString("Recording… (press %@ to stop)", comment: ""), primaryShortcutDisplay))
                .font(.system(size: DesignFont.sm))
                .foregroundStyle(Color.neutral12)
        case .finalizing:
            HStack(spacing: DesignSpacing.xxxs) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Finalizing…", comment: "")).font(.system(size: DesignFont.sm)).foregroundStyle(Color.neutral9)
            }
        case .committing:
            HStack(spacing: DesignSpacing.xxxs) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Processing…", comment: "")).font(.system(size: DesignFont.sm)).foregroundStyle(Color.neutral9)
            }
        }
    }

    // MARK: - Helpers

    /// Get primary shortcut display string from dictation action
    private var primaryShortcutDisplay: String {
        guard let dictationAction = shortcutStore.actions.first(where: { $0.id == "dictation" }),
              !dictationAction.primaryShortcut.isEmpty else {
            return "FN"
        }
        return shortcutDisplayKeys(dictationAction.primaryShortcut).joined(separator: "+")
    }
}

// MARK: - Step card

private struct StepCard: View {

    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .center, spacing: DesignSpacing.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignRadius.md)
                    .fill(Color.primary1)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.primary8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.neutral12)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.neutral9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignSpacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.lg)
                .fill(Color.neutral2)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignRadius.lg)
                        .strokeBorder(Color.neutral3, lineWidth: 1)
                )
        )
    }
}
