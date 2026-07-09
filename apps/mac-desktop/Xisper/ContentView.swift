import SwiftData
import SwiftUI

// MARK: - Navigation notifications (shared with RecordingCoordinator)

extension Notification.Name {
    /// Posted when recording fails due to not being authenticated.
    static let navigateToAuth = Notification.Name("navigateToAuth")
    /// Posted when recording fails due to missing permissions (microphone or accessibility).
    static let navigateToPermissions = Notification.Name("navigateToPermissions")
    /// Posted when recording is auto-stopped due to prolonged silence.
    static let recordingStoppedDueToSilence = Notification.Name("recordingStoppedDueToSilence")
}

// MARK: - Environment keys for sidebar state

private struct SidebarToggleActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct SidebarIsHiddenKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var sidebarToggleAction: (() -> Void)? {
        get { self[SidebarToggleActionKey.self] }
        set { self[SidebarToggleActionKey.self] = newValue }
    }
    var sidebarIsHidden: Bool {
        get { self[SidebarIsHiddenKey.self] }
        set { self[SidebarIsHiddenKey.self] = newValue }
    }
}

// MARK: - Debug log (DEBUG only, /tmp/xisper-sidebar-debug.log)

#if DEBUG
private func sidebarDebugLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/xisper-sidebar-debug.log")
    do {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let data = line.data(using: .utf8),
              let fh = try? FileHandle(forWritingTo: url) else { return }
        defer { fh.closeFile() }
        fh.seekToEndOfFile()
        try fh.write(contentsOf: data)
    } catch {}
}
#endif

// MARK: - Root router

struct ContentView: View {

    @Bindable private var authManager = AuthManager.shared
    @Bindable private var permManager = PermissionsManager.shared

    var body: some View {
        Group {
            if !authManager.isAuthenticated {
                AuthView()
            } else if !permManager.allGranted {
                PermissionsView()
            } else {
                MainView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // AppDelegate.applicationWillUpdate sets fullSizeContentView + titlebarAppearsTransparent
        // before SwiftUI's first layout, so the safe area is already set when we get here.
        // ignoresSafeArea MUST be outermost (after .frame) so it intercepts the ~28pt
        // titlebar safe area before .frame caps the available height.
        .ignoresSafeArea(.all, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAuth)) { _ in
            // Reset auth state to trigger navigation to AuthView
            authManager.resetAuthState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPermissions)) { _ in
            // Refresh permissions and trigger navigation to PermissionsView
            permManager.refresh()
        }
    }
}

// MARK: - Main view

private struct MainView: View {

    @State private var selection: SidebarSection? = SidebarSection.lastSelected
    @State private var isSidebarVisible = true
    @State private var showSilenceBanner = false

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                SidebarView(selection: $selection)
                    .frame(width: 220)
                Divider()
            }
            VStack(spacing: 0) {
                // Silence auto-stop banner
                if showSilenceBanner {
                    SilenceAutostopBanner {
                        withAnimation(.easeOut(duration: 0.2)) { showSilenceBanner = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Environment on the HStack so both sidebar and detail can read toggle/state
        .environment(\.sidebarToggleAction) {
            withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
        }
        .environment(\.sidebarIsHidden, !isSidebarVisible)
        .onChange(of: selection) { _, new in
            if let new { SidebarSection.lastSelected = new }
            CrashLogger.log("ContentView", "detail switched to \(new?.rawValue ?? "nil")")
        }
        .frame(minWidth: 1200, minHeight: 800)
        .onAppear {
            HotkeySystem.shared.start()
            RecordingCoordinator.shared.schedulePipelineWarmup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSection)) { note in
            if let section = note.object as? SidebarSection {
                selection = section
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingStoppedDueToSilence)) { _ in
            withAnimation(.easeIn(duration: 0.2)) { showSilenceBanner = true }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .home, nil:   HomeView()
        case .history:     HistoryView()
        case .analytics:   AnalyticsView()
        case .hotwords:    HotwordsView()
        case .settings:    SettingsView()
        }
    }
}

// MARK: - Silence auto-stop banner

private struct SilenceAutostopBanner: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignSpacing.xs) {
            Image(systemName: "mic.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warning9)
            Text(NSLocalizedString("Recording auto-stopped after 3 minutes of silence", comment: "Silence auto-stop banner"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.neutral12)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.neutral7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSpacing.md)
        .padding(.vertical, 8)
        .background(Color.warning3)
    }
}

// MARK: - Navigation notification

extension Notification.Name {
    /// Posted by TrayView (or other non-SwiftUI code) to navigate to a sidebar section.
    /// The `object` should be a `SidebarSection` value.
    static let navigateToSection = Notification.Name("navigateToSection")
    /// Posted when audio input devices change (Bluetooth connect/disconnect, etc.).
    static let audioDeviceListChanged = Notification.Name("audioDeviceListChanged")
}

// MARK: - Sidebar sections

enum SidebarSection: String, CaseIterable, Hashable {
    case home, history, analytics, hotwords, settings

    /// Persists across view recreation (e.g. language switch refreshUI).
    static var lastSelected: SidebarSection = .home

    var icon: String {
        switch self {
        case .home:      "house.fill"
        case .history:   "clock.fill"
        case .analytics: "chart.bar.fill"
        case .hotwords:  "text.badge.plus"
        case .settings:  "gearshape.fill"
        }
    }

    var label: String {
        switch self {
        case .home:      NSLocalizedString("Home", comment: "")
        case .history:   NSLocalizedString("History", comment: "")
        case .analytics: NSLocalizedString("Analytics", comment: "")
        case .hotwords:  NSLocalizedString("Hotwords", comment: "")
        case .settings:  NSLocalizedString("Settings", comment: "")
        }
    }
}

// MARK: - Identity icons

let identityIcons: [String: String] = [
    "developer": "terminal",
    "general-tech": "cpu",
    "doctor": "heart.text.square",
    "lawyer": "scale.3d",
    "finance": "chart.line.uptrend.xyaxis",
    "product-manager": "square.grid.2x2",
]

func identityIcon(for id: String?) -> String {
    guard let id else { return "briefcase" }
    return identityIcons[id] ?? "briefcase"
}

// MARK: - Custom header row (space-between layout, lives in view body not toolbar)

struct PageHeader<C: View>: View {
    var title: String?
    var badge: String?
    var center: C

    @Environment(\.sidebarToggleAction) private var toggleSidebar
    @Environment(\.sidebarIsHidden) private var sidebarIsHidden

    var body: some View {
        HStack(spacing: DesignSpacing.xs) {
            // Left spacer: when sidebar is hidden, reserve space for traffic lights (red/yellow/green)
            // Standard macOS traffic lights in fullSizeContentView:
            //   • Red (close):     x ≈ 13pt, diameter ≈ 12pt
            //   • Yellow (min):    x ≈ 33pt, diameter ≈ 12pt
            //   • Green (zoom):    x ≈ 53pt, diameter ≈ 12pt
            //   • Total width:     ~68pt from left edge
            //   • Y position:      ~13-16pt from top (centered in titlebar)
            // Reserve 75pt to ensure toggle button doesn't overlap with traffic lights
            if sidebarIsHidden {
                Spacer()
                    .frame(width: 32)
            }
            
            // Sidebar toggle — only visible in PageHeader when sidebar is collapsed.
            // When sidebar is expanded it appears as an overlay on the sidebar itself.
            if let toggleSidebar, sidebarIsHidden {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.neutral9)
                }
                .buttonStyle(.plain)
            }

            if let title {
                HStack(spacing: DesignSpacing.xxs) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.neutral12)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.neutral9)
                            .padding(.horizontal, DesignSpacing.xs)
                            .frame(height: 20)
                            .background(Color.neutral3)
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
            center
            Spacer(minLength: 0)
            IdentityMenuButton()
        }
        .padding(.horizontal, DesignSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Color.neutral1)
        .contentShape(Rectangle())
        .windowDrag()
    }
}

extension PageHeader {
    init(title: String? = nil, badge: String? = nil, @ViewBuilder center: () -> C) {
        self.title = title
        self.badge = badge
        self.center = center()
    }
}

extension PageHeader where C == EmptyView {
    init(title: String? = nil, badge: String? = nil) {
        self.title = title
        self.badge = badge
        self.center = EmptyView()
    }
}

// MARK: - Identity menu button (shared across toolbars)

struct IdentityMenuButton: View {
    private var identity: IdentityManager { IdentityManager.shared }
    private var isActive: Bool { identity.activeIdentityId != nil }
    
    @State private var showMenu = false

    var body: some View {
        Button {
            showMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: identityIcon(for: identity.activeIdentityId))
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Color.primary8 : Color.neutral9)
                Text(identity.activeLocalizedLabel ?? NSLocalizedString("Identity", comment: ""))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Color.primary8 : Color.neutral12)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.neutral7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DesignRadius.md)
                    .fill(isActive ? Color.primary8.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignRadius.md)
                    .strokeBorder(isActive ? Color.primary8.opacity(0.4) : Color.neutral5, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // None option
                Button {
                    identity.setActiveIdentity(nil)
                    showMenu = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.neutral9)
                            .frame(width: 16)
                        Text(NSLocalizedString("None", comment: "Identity menu"))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.neutral12)
                        Spacer()
                        if identity.activeIdentityId == nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                Divider()
                    .padding(.vertical, 4)
                
                // Identity options
                ForEach(identity.availableIdentities, id: \.id) { item in
                    Button {
                        identity.setActiveIdentity(item.id)
                        showMenu = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: identityIcon(for: item.id))
                                .font(.system(size: 13))
                                .foregroundStyle(Color.neutral9)
                                .frame(width: 16)
                            Text(IdentityManager.localizedLabel(for: item.id, fallback: item.label))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.neutral12)
                            Spacer()
                            if identity.activeIdentityId == item.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.primary8)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minWidth: 180)
            .padding(.vertical, 6)
            .background(Color.neutral1)
        }
        .fixedSize()
        .onAppear {
            Task { await identity.fetchAvailableIdentities() }
        }
    }
}

// MARK: - Sidebar view

private struct SidebarView: View {

    @Binding var selection: SidebarSection?

    private var auth: AuthManager { AuthManager.shared }
    @State private var usage = UsageManager.shared
    @Environment(\.sidebarToggleAction) private var toggleSidebar

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar header row — same height as detail PageHeader (56 pt).
            ZStack(alignment: .topTrailing) {
                Color.neutral1
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                if let action = toggleSidebar {
                    Button(action: action) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.neutral9)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                    .padding(.trailing, 10)
                }
            }

            List(SidebarSection.allCases, id: \.self, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .symbolRenderingMode(.hierarchical)
                    .tag(section)
                    .padding(.vertical, DesignSpacing.xxxs)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.neutral1)
            .frame(maxHeight: .infinity)

            // ── Sidebar bottom: account + usage ──
            VStack(alignment: .leading, spacing: 12) {

                // Account row: avatar + (email + tier badge)
                HStack(spacing: 10) {
                    let initial = String((auth.userEmail ?? "U").prefix(1)).uppercased()
                    ZStack {
                        Circle()
                            .fill(Color.primary8)
                            .frame(width: 28, height: 28)
                        Text(initial)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text(auth.userEmail ?? NSLocalizedString("Account", comment: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.neutral12)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    if !usage.isUnlimitedTier {
                        Text(usage.tier.capitalized)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.neutral9)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.neutral3)
                            .clipShape(RoundedRectangle(cornerRadius: DesignRadius.xs))
                            .fixedSize()
                    }
                }
                .padding(.top, 12)
                .overlay(alignment: .top) {
                    Color.neutral3.frame(height: 1).padding(.horizontal, -12)
                }
                #if DEBUG
                .onAppear { sidebarDebugLog("Account row onAppear, email=\(auth.userEmail ?? "nil")") }
                #endif

                // Unlimited: premium identity only (no usage meter). Other tiers: used/limit + bar.
                if usage.isUnlimitedTier {
                    unlimitedSidebarCard
                } else if usage.showsFiniteCharacterQuotaBar {
                    let fraction = usage.asrCharacters.fraction
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(NSLocalizedString("Character Tokens", comment: ""))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.neutral7)
                            Spacer()
                            Text("\(formatNumber(usage.asrCharacters.used)) / \(formatNumber(usage.asrCharacters.limit))")
                                .font(.system(size: 10, weight: .medium).monospaced())
                                .foregroundStyle(Color.neutral9)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: .infinity)
                                    .fill(Color.neutral3)
                                    .frame(maxWidth: .infinity)
                                RoundedRectangle(cornerRadius: .infinity)
                                    .fill(barColor(fraction))
                                    .frame(width: max(0, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, DesignSpacing.xxs)
            .background(Color.neutral1)
            .onAppear {
                #if DEBUG
                sidebarDebugLog("Bottom section onAppear (email + tier + ASR)")
                #endif
                usage.startAutoRefresh()
            }
        }
        .background(Color.neutral1)
    }

    /// Premium sidebar treatment for `unlimited` tier — identity only, no metering UI.
    private var unlimitedSidebarCard: some View {
        HStack(alignment: .center, spacing: DesignSpacing.icon_gap) {
            Image(systemName: "infinity")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary8)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Unlimited", comment: ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.neutral12)
                Text(NSLocalizedString("No usage limits", comment: ""))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.neutral7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSpacing.xxxs)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignRadius.md)
                .fill(Color.primary8.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignRadius.md)
                .stroke(Color.primary8.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func barColor(_ fraction: Double) -> Color {
        if fraction >= 0.9 { return .danger8 }
        if fraction >= 0.7 { return .warning8 }
        return .primary8
    }

    private func formatNumber(_ n: Int) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        return fmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
