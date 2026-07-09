/**
 * LiveTranscribePanel
 *
 * Floating capsule HUD shown during recording.
 * Screen center, 4/5 from top.
 *
 * Waveform: per-bar sine-wave overlay at 30 fps.
 * Asymmetric 11-bar config + power-compressed volume + silent→flat transition.
 */

import AppKit
import SwiftUI

// MARK: - Tunable Config ──────────────────────────────────────────────

/// Adjust these to change look and feel.
private enum BubbleConfig {
    /// Size multiplier for capsule + bars (loading dots unaffected).
    static let scale: CGFloat = 1

    // ── Derived dimensions (change `scale` above, these follow) ──
    static let capsuleW: CGFloat = 108 * scale
    static let capsuleH: CGFloat =  36 * scale
    static let panelW:   CGFloat = capsuleW + 60
    static let panelH:   CGFloat = capsuleH + 60
}

// MARK: - App-level bubble manager (independent of any window)

/// Observes RecordingCoordinator.state and shows/hides the floating bubble.
/// Lives at AppDelegate level so the bubble survives main window close.
@MainActor
final class BubblePanelManager {
    static let shared = BubblePanelManager()
    private var panel: LiveBubbleNSPanel?

    func startObserving() {
        warmUpPanel()
        observe()
    }

    /// Pre-create the panel (hidden) so the first show is instant.
    private func warmUpPanel() {
        if panel == nil {
            panel = LiveBubbleNSPanel()
            panel?.orderOut(nil)
        }
    }

    private func observe() {
        let coordinator = RecordingCoordinator.shared
        let shouldShow = withObservationTracking {
            coordinator.state != .idle || coordinator.showBubbleError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        CrashLogger.log("BubblePanelManager", "state=\(coordinator.state) bubbleError=\(coordinator.showBubbleError) shouldShow=\(shouldShow)")
        if shouldShow { showPanel() } else { hidePanel() }
    }

    private func showPanel() {
        if panel == nil {
            CrashLogger.log("BubblePanelManager", "creating new panel")
            panel = LiveBubbleNSPanel()
        }
        panel?.snapToScreen()
        panel?.orderFront(nil)
    }

    private func hidePanel() {
        CrashLogger.log("BubblePanelManager", "hidePanel")
        panel?.orderOut(nil)
    }
}

// MARK: - NSPanel

final class LiveBubbleNSPanel: NSPanel {

    private let hostingView: NSHostingView<LiveBubbleContent>

    init() {
        let size = CGSize(width: BubbleConfig.panelW, height: BubbleConfig.panelH)
        hostingView = NSHostingView(rootView: LiveBubbleContent())
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel             = true
        level                       = .statusBar          // above fullscreen apps
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        isOpaque                    = false
        backgroundColor             = .clear
        hasShadow                   = false
        ignoresMouseEvents          = false
        contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
        snapToScreen()
    }

    /// Position bubble above the current mouse cursor on whichever screen it's on.
    /// Falls back to screen-center if cursor position is unavailable.
    func snapToScreen() {
        let mouse = NSEvent.mouseLocation
        // Find the screen the cursor is currently on; fall back to main screen.
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return }

        let pw = BubbleConfig.panelW, ph = BubbleConfig.panelH
        // Horizontally centered on the screen, vertically 1/5 from bottom.
        let x = sf.midX - pw / 2
        let y = sf.minY + sf.height * 0.20 - ph / 2
        setFrame(clampToScreen(NSRect(x: x, y: y, width: pw, height: ph), screen: screen),
                 display: true)
    }

    private func clampToScreen(_ r: NSRect, screen: NSScreen?) -> NSRect {
        guard let sc = (screen ?? NSScreen.main)?.visibleFrame else { return r }
        var o = r
        o.origin.x = max(sc.minX, min(o.origin.x, sc.maxX - o.width))
        o.origin.y = max(sc.minY + 10, min(o.origin.y, sc.maxY - o.height))
        return o
    }
}

// MARK: - Bubble Content

/// Fixed-size capsule — same dimensions for recording AND processing states.
private struct LiveBubbleContent: View {
    private var coordinator: RecordingCoordinator { .shared }

    private var isTranslateMode: Bool {
        coordinator.currentActionId == "translate"
    }

    private var isError: Bool {
        coordinator.showBubbleError
    }

    /// Corner radius: full capsule when normal, top-right becomes sharp in translate mode.
    private var bubbleShape: UnevenRoundedRectangle {
        let r = BubbleConfig.capsuleH / 2 // full capsule radius
        let tr: CGFloat = isTranslateMode && !isError ? 4 : r // top-right: sharp(4pt) vs round
        return UnevenRoundedRectangle(
            topLeadingRadius: r,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: tr
        )
    }

    var body: some View {
        ZStack {
            bubbleShape
                .fill(isError ? Color.danger3 : Color.primary3)

            if isError {
                BubbleErrorView()
            } else {
                switch coordinator.state {
                case .recording:
                    EnergyBarsView()
                case .finalizing, .committing:
                    LoadingDotsView()
                case .idle:
                    EmptyView()
                }
            }

            // Translate icon in the sharp top-right corner
            if isTranslateMode && !isError && coordinator.state != .idle {
                Image(systemName: "translate")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.primary9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 4)
                    .padding(.trailing, 3)
                    .transition(.opacity)
            }
        }
        .frame(width: BubbleConfig.capsuleW, height: BubbleConfig.capsuleH)
        .animation(.fast, value: coordinator.state)
        .animation(.fast, value: isTranslateMode)
        .animation(.fast, value: isError)
    }
}

// MARK: - Bubble Error View

/// Shows a brief error indicator: shake icon + red tint.
private struct BubbleErrorView: View {
    @State private var shake = false

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.danger9)
            .rotationEffect(.degrees(shake ? -8 : 8))
            .animation(
                .easeInOut(duration: 0.12).repeatCount(5, autoreverses: true),
                value: shake
            )
            .onAppear { shake = true }
    }
}


// MARK: - Per-bar wave config

/// Each bar has its own rhythm (period) for lively feel + delay from center for
/// subtle directional bias. Right side slightly higher amplitude for asymmetry.
private struct BarConfig {
    let amplitude: Float
    let period: Float
    let delay: Float
}

private let kBarConfigs: [BarConfig] = [
    BarConfig(amplitude: 0.22, period: 0.82, delay: 0.16),  // 0  left edge
    BarConfig(amplitude: 0.30, period: 0.68, delay: 0.11),  // 1
    BarConfig(amplitude: 0.38, period: 0.90, delay: 0.07),  // 2
    BarConfig(amplitude: 0.44, period: 0.72, delay: 0.03),  // 3
    BarConfig(amplitude: 0.45, period: 0.78, delay: 0),      // 4  center
    BarConfig(amplitude: 0.40, period: 0.65, delay: 0.03),  // 5
    BarConfig(amplitude: 0.50, period: 0.85, delay: 0.07),  // 6  peak
    BarConfig(amplitude: 0.35, period: 0.72, delay: 0.12),  // 7
    BarConfig(amplitude: 0.28, period: 0.80, delay: 0.17),  // 8  right edge
]

// MARK: - Waveform Engine

/// Per-bar independent sine waves at 30 fps.
/// Each bar dances at its own period for lively, organic feel.
/// Noise gate → flat line when silent.
@Observable
final class WaveformEngine {
    static let barCount = kBarConfigs.count

    var barHeights: [CGFloat] = Array(repeating: 0, count: kBarConfigs.count)

    private static let minH: CGFloat = 2 * BubbleConfig.scale
    private static let maxH: CGFloat = 22 * BubbleConfig.scale
    private static let rest: Float = 0.024
    /// Levels below this are treated as silence (bars stay flat).
    /// Typical values: quiet room ≈ 0.01–0.05, speech ≈ 0.10–0.50.
    /// Set above your ambient noise floor so bars only move on actual speech.
    private static let noiseGate: Float = 0.032

    private var currentLevel: Float = 0
    private var smoothedVolume: Float = 0
    private var elapsed: Float = 0

    private var timerSource: DispatchSourceTimer?

    func start() {
        elapsed = 0
        smoothedVolume = 0
        barHeights = Array(repeating: Self.fractionToPixel(Self.rest), count: Self.barCount)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        t.resume()
        timerSource = t
    }

    func stop() {
        timerSource?.cancel(); timerSource = nil
        barHeights = Array(repeating: Self.fractionToPixel(Self.rest), count: Self.barCount)
    }

    func setLevel(_ v: Float) { currentLevel = v }

    @MainActor
    private func tick() {
        let dt: Float = 1.0 / 30.0
        elapsed += dt

        let gated = currentLevel > Self.noiseGate ? currentLevel : Float(0)
        let compressed = gated > 0 ? powf(gated, 0.35) : 0
        let lerp: Float = compressed > smoothedVolume ? 0.7 : 0.15
        smoothedVolume += (compressed - smoothedVolume) * lerp

        let isLowVolume = smoothedVolume < 0.02
        let baseHeight = Self.rest + smoothedVolume * 0.75

        barHeights = (0..<Self.barCount).map { i in
            let fraction: Float
            if isLowVolume {
                fraction = Self.rest
            } else {
                let cfg = kBarConfigs[i]
                let phase = ((elapsed + cfg.delay).truncatingRemainder(dividingBy: cfg.period)) / cfg.period
                let wave = sinf(2 * .pi * phase)
                let waveScale = 1 + cfg.amplitude * wave
                fraction = max(Self.rest, min(baseHeight * waveScale, 1.0))
            }
            return Self.fractionToPixel(fraction)
        }
    }

    private static func fractionToPixel(_ f: Float) -> CGFloat {
        minH + (maxH - minH) * CGFloat(max(rest, min(f, 1.0)))
    }
}

// MARK: - Energy Bars View

private struct EnergyBarsView: View {
    /// Read audioLevel here (not in parent LiveBubbleContent) so that
    /// audioLevel changes only invalidate this view, not the entire bubble.
    private var level: Float { RecordingCoordinator.shared.audioLevel }

    @State private var engine = WaveformEngine()
    private let s = BubbleConfig.scale

    var body: some View {
        HStack(alignment: .center, spacing: 3 * s) {
            ForEach(0..<WaveformEngine.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5 * s)
                    .fill(Color.primary9)
                    .frame(width: 3 * s, height: engine.barHeights[i])
                    .animation(.easeInOut(duration: 0.06), value: engine.barHeights[i])
            }
        }
        .onChange(of: level) { _, v in engine.setLevel(v) }
        .onAppear  { engine.setLevel(level); engine.start() }
        .onDisappear { engine.stop() }
    }
}

// MARK: - Loading Dots  (finalizing / committing — NOT scaled)

private struct LoadingDotsView: View {
    @State private var active = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.primary9)
                    .frame(width: 4, height: 4)
                    .scaleEffect(active == i ? 1.2 : 0.85)
                    .opacity(active == i ? 1.0 : 0.35)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: active)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: true) { _ in
                Task { @MainActor in active = (active + 1) % 3 }
            }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
}
