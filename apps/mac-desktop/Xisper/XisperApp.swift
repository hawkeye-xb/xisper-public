import Sparkle
import SwiftData
import SwiftUI

// MARK: - Sparkle user-driver delegate (activates app when update UI appears)

final class SparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// Called when Sparkle is about to show the update alert.
    /// The app is already .regular (Dock icon visible), but after the
    /// MenuBarExtra popover dismisses, macOS may not give focus back.
    /// Explicit activate ensures the Sparkle dialog comes to front.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// App entry point.
///
/// The main window is created manually by AppDelegate so that
/// fullSizeContentView is in the style mask from birth — no timing gap,
/// no safe-area flip on first render.  Only the MenuBarExtra is declared here.
@main
struct XisperApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Shared SwiftData container — accessible by RecordingCoordinator and SwiftUI views.
    /// Uses app-specific directory to prevent collision with other processes
    /// (icloudmailagent destroyed data at the shared ~/Library/Application Support/default.store).
    static let modelContainer: ModelContainer = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent(AppEnvironment.appSupportFolderName, isDirectory: true)
        try! FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        let storeURL = appDir.appendingPathComponent("TranscribeRecords.store")

        // Migrate from the old shared default.store if our app-specific store doesn't exist yet
        if !FileManager.default.fileExists(atPath: storeURL.path) {
            let sharedStore = appSupport.appendingPathComponent("default.store")
            if FileManager.default.fileExists(atPath: sharedStore.path) {
                for ext in ["", "-shm", "-wal"] {
                    let src = URL(fileURLWithPath: sharedStore.path + ext)
                    let dst = URL(fileURLWithPath: storeURL.path + ext)
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
        }

        let config = ModelConfiguration("TranscribeRecords", url: storeURL)
        return try! ModelContainer(for: TranscribeRecord.self, configurations: config)
    }()

    // Sparkle updater — userDriverDelegate activates app so update dialog gets focus.
    private static let sparkleDriverDelegate = SparkleUserDriverDelegate()

    #if DEBUG
    static let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: sparkleDriverDelegate)
    #else
    static let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: sparkleDriverDelegate)
    #endif

    // Configure update check interval to 2 hours for faster critical update delivery
    static func configureUpdater() {
        updaterController.updater.updateCheckInterval = 2 * 3600  // 2 hours
    }

    var body: some Scene {
        // ── Menu-bar tray: small status popover (recording indicator + Open button) ──
        MenuBarExtra {
            TrayView()
        } label: {
            Label {
                Text(AppEnvironment.appDisplayName)
            } icon: {
                Image("XisperTray")
                    .renderingMode(.template)
            }
        }
        .menuBarExtraStyle(.window)
        .modelContainer(XisperApp.modelContainer)
    }
}
