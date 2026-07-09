import SwiftUI

/// Sign-in screen — matches pen design (frame 5hbHa).
/// Two states: idle (Sign in with Browser) and loading (Waiting for browser).
struct AuthView: View {

    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // ── Main content (centered vertically) ──
            VStack(spacing: DesignSpacing.sm) {
                // Header: logo + title + subtitle
                VStack(spacing: DesignSpacing.xxxs) {
                    Image("XisperIcon")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 48, height: 48)

                    Text(NSLocalizedString("Sign in to Xisper", comment: ""))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.neutral12)

                    Text(NSLocalizedString("Authenticate to continue using Xisper", comment: ""))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.neutral9)
                }

                // State area
                if let error = errorMessage {
                    errorState(message: error)
                } else if isLoading {
                    loadingState
                } else {
                    idleState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Footer: terms + privacy ──
            HStack(spacing: 4) {
                Text(NSLocalizedString("By signing in, you agree to our", comment: ""))
                    .foregroundStyle(Color.neutral7)
                Link(NSLocalizedString("Terms", comment: ""),
                     destination: URL(string: "https://xisper-landing.hawkeye-xb.com/terms")!)
                     .foregroundStyle(Color.primary8)
                Text(NSLocalizedString("and", comment: ""))
                    .foregroundStyle(Color.neutral7)
                Link(NSLocalizedString("Privacy", comment: ""),
                     destination: URL(string: "https://xisper-landing.hawkeye-xb.com/privacy")!)
                     .foregroundStyle(Color.primary8)
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.neutral1.ignoresSafeArea())
    }

    // MARK: - Idle state

    private var idleState: some View {
        VStack(spacing: 12) {
            Button(action: { signIn(forceRelogin: false) }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 16))
                    Text(NSLocalizedString("Sign in with Browser", comment: ""))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.onPrimary)
                .frame(width: 260, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.md)
                        .fill(Color.primary8)
                )
            }
            .buttonStyle(.plain)

            Button(NSLocalizedString("Switch Account", comment: "")) {
                signIn(forceRelogin: true)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.neutral7)
        }
    }

    // MARK: - Loading state

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)

            Text(NSLocalizedString("Waiting for browser...", comment: ""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.neutral12)

            Text(NSLocalizedString("Complete sign-in in your browser, then return here.", comment: ""))
                .font(.system(size: 12))
                .foregroundStyle(Color.neutral9)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(NSLocalizedString("Cancel", comment: "")) {
                AuthManager.shared.cancelLogin()
                isLoading = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.neutral7)
        }
    }

    // MARK: - Error state

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Color.danger8)

            Text(NSLocalizedString("Authentication failed", comment: ""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.neutral12)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.neutral9)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(action: { errorMessage = nil }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                    Text(NSLocalizedString("Try Again", comment: ""))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Color.onPrimary)
                .frame(width: 200, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: DesignRadius.md)
                        .fill(Color.primary8)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Action

    private func signIn(forceRelogin: Bool = false) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await AuthManager.shared.login(forceRelogin: forceRelogin)
            } catch {
                let cancelled = (error as NSError).code == 1
                if !cancelled {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
            await MainActor.run { isLoading = false }
        }
    }
}
