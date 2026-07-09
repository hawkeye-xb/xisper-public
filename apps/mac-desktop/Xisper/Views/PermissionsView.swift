import SwiftUI

/// Permissions onboarding — matches pen design (frame CeZLh).
/// Header (gradient icon + title + description) → permission rows → Continue + Skip + help.
struct PermissionsView: View {

    var body: some View {
        let perm = PermissionsManager.shared

        ZStack {
            // Full-bleed fill so the 480pt content column does not leave window default chrome at the sides.
            Color.neutral1.ignoresSafeArea()

            VStack(spacing: DesignSpacing.sm) {

            // ── Header ──
            VStack(spacing: 12) {
                // Custom app icon
                Image("XisperIcon")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                Text(AppEnvironment.appDisplayName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.neutral12)

                Text(String(format: NSLocalizedString("%@ needs a few permissions to work properly. Grant access below to get started.", comment: ""), AppEnvironment.appDisplayName))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.neutral9)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            // ── Permission list ──
            VStack(spacing: 0) {
                PermissionRow(
                    icon: "mic",
                    iconColor: Color.primary8,
                    iconBg: Color.primary1,
                    title: NSLocalizedString("Microphone", comment: ""),
                    description: NSLocalizedString("Required for voice transcription", comment: ""),
                    granted: perm.microphoneGranted,
                    action: { perm.requestMicrophone() }
                )
                .overlay(alignment: .bottom) { Color.neutral3.frame(height: 1) }

                PermissionRow(
                    icon: "accessibility",
                    iconColor: Color.info8,
                    iconBg: Color.info1,
                    title: NSLocalizedString("Accessibility", comment: ""),
                    description: NSLocalizedString("Needed for global hotkey & text paste", comment: ""),
                    granted: perm.accessibilityGranted,
                    action: { perm.requestAccessibility() }
                )
            }

            // ── Footer ──
            VStack(spacing: 12) {
                Button(action: { /* routing reacts to allGranted automatically */ }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16))
                        Text(NSLocalizedString("Continue", comment: ""))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.onPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.md)
                            .fill(Color.primary8)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!perm.allGranted)
                .opacity(perm.allGranted ? 1 : 0.5)
            }

            Text(NSLocalizedString("You can change permissions later in System Settings > Privacy & Security", comment: ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.neutral7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }
            .padding(DesignSpacing.sm)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Note: Don't call refresh() here automatically - AVAuthorizationStatus caches per process
        // Let each permission button trigger its own refresh when clicked
    }
}

// MARK: - Permission row

private struct PermissionRow: View {

    let icon: String
    let iconColor: Color
    let iconBg: Color
    let title: String
    let description: String
    var isOptional: Bool = false
    let granted: Bool
    var grantLabel: String? = nil
    let action: () -> Void
    
    private var effectiveGrantLabel: String {
        grantLabel ?? NSLocalizedString("Grant", comment: "")
    }

    var body: some View {
        HStack(spacing: 14) {
            // Icon box
            ZStack {
                RoundedRectangle(cornerRadius: DesignRadius.md)
                    .fill(iconBg)
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)
            }

            // Title + description
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.neutral12)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.neutral9)
            }

            Spacer()

            // Status badge or action button
            if granted {
                BadgeView(text: NSLocalizedString("Granted", comment: ""), color: Color.success8, bg: Color.success1)
            } else if isOptional {
                BadgeView(text: NSLocalizedString("Optional", comment: ""), color: Color.warning8, bg: Color.warning1)
            } else {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 14))
                        Text(effectiveGrantLabel)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.onPrimary)
                    .padding(.horizontal, DesignSpacing.xxs)
                    .padding(.vertical, DesignSpacing.xxxs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignRadius.md)
                            .fill(Color.primary8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DesignSpacing.xxs)
    }
}

// MARK: - Badge view

private struct BadgeView: View {
    let text: String
    let color: Color
    let bg: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, DesignSpacing.xxxs)
            .padding(.vertical, DesignSpacing.xxxxs)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.sm))
    }
}
