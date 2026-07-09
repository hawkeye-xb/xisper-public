import Foundation

/// Centralized environment configuration derived from build configuration and bundle ID.
enum AppEnvironment {

    /// Whether this build targets the dev backend.
    /// DEBUG builds always use dev; Release builds use dev only for `.beta` bundle IDs.
    static var isDevBackend: Bool {
        #if DEBUG
        return true
        #else
        let id = Bundle.main.bundleIdentifier ?? ""
        return id.hasSuffix(".beta")
        #endif
    }

    /// Environment name: "production" or "beta".
    /// Determined by bundle ID suffix.
    static var environmentName: String {
        isDevBackend ? "beta" : "production"
    }

    /// Base URL for all backend API calls.
    static var serviceBaseURL: String {
        isDevBackend
            ? "https://xisper-dev.hawkeye-xb.com"
            : "https://xisper.hawkeye-xb.com"
    }

    /// Logto OAuth app ID.
    static var logtoAppId: String {
        isDevBackend
            ? "2mepw39zb3jt55dnht427"
            : "vnd5x8k6zuotvpfm4o5tc"
    }

    /// Logto OIDC endpoint.
    static let logtoEndpoint = "https://fn2daz.logto.app"

    /// OAuth callback URL scheme.
    /// Beta uses a separate scheme to prevent callback conflicts between environments.
    static var callbackScheme: String {
        isDevBackend ? "xisper-mac-beta" : "xisper-mac"
    }

    /// OAuth redirect URI.
    static var redirectURI: String {
        "\(callbackScheme)://auth/callback"
    }

    // MARK: - App Info

    /// App display name for UI (includes environment suffix).
    static var appDisplayName: String {
        isDevBackend ? "Xisper (Beta)" : "Xisper"
    }

    /// Bundle display name (shown in Finder, Dock, Spotlight).
    static var bundleDisplayName: String {
        appDisplayName
    }

    /// Short version string for display (e.g., "1.0.0" or "0.0.1-beta").
    /// Beta uses development version format.
    static var shortVersionString: String {
        #if DEBUG
        return "0.0.1-dev"
        #else
        return isDevBackend ? "0.6.1-beta" : "0.6.1"
        #endif
    }

    // MARK: - Local Storage

    /// Application Support folder name.
    /// Production: "Xisper", Beta: "XisperBeta"
    static var appSupportFolderName: String {
        environmentName == "beta" ? "XisperBeta" : "Xisper"
    }

    /// UserDefaults suite name for environment-specific storage.
    /// Uses App Group format to allow potential future sharing.
    static var defaultsSuiteName: String {
        "group.xyz.hawkeye-xb.xisper-\(environmentName)"
    }

    /// Crash log file name (includes environment).
    static var crashLogFileName: String {
        "xisper-\(environmentName)-crash-debug.log"
    }

    /// Auth log file name (includes environment).
    static var authLogFileName: String {
        "xisper-\(environmentName)-auth.log"
    }

    // MARK: - Auto Update

    /// Sparkle appcast feed URL.
    static var appcastURL: String {
        isDevBackend
            ? "https://xisper-dev.hawkeye-xb.com/api/v1/app/mac/updates/feed/beta"
            : "https://xisper.hawkeye-xb.com/api/v1/app/mac/updates/feed/production"
    }
}
