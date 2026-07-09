/**
 * RecordingCoordinator
 *
 * Central state machine for a recording session.  Replaces RecordingCoordinator.ts.
 *
 * State machine:
 *   idle → recording → finalizing → committing → idle
 *
 * Key behaviours (matching Electron constants):
 *   MISTOUCH_THRESHOLD  200 ms  — discard recordings shorter than this
 *   STOP_DELAY          50  ms  — capture trailing audio after key-up
 *   ASR_FINAL_TIMEOUT   8   s   — give up waiting for is_last_package
 */

import AppKit
import AVFoundation
import Foundation
import SwiftData

// MARK: - File Logger (temporary debug)

private let recLogFile = URL(fileURLWithPath: "/tmp/xisper-recording.log")

private func recLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if !FileManager.default.fileExists(atPath: recLogFile.path) {
            FileManager.default.createFile(atPath: recLogFile.path, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: recLogFile) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }
}

// MARK: - Session state

enum RecordingState: Equatable {
    case idle
    case recording
    case finalizing
    case committing
}

// MARK: - RecordingCoordinator

@Observable
@MainActor
final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    // MARK: - Observable state

    private(set) var state:     RecordingState = .idle
    private(set) var liveText:  String = ""
    private(set) var lastText:  String = ""
    private(set) var errorMessage: String? = nil
    private(set) var audioLevel: Float = 0

    /// Transient flag: show error state in bubble for ~2s before hiding.
    private(set) var showBubbleError: Bool = false

    /// Which hotkey action started this session ("dictation" or "translate").
    private(set) var currentActionId: String?

    // MARK: - Private

    private let audioEngine = AudioEngine()
    private var asrClient:  ASRClient?

    private var currentRecordingId: String?
    private var recordingStart:    Date?
    private var firstPacketTime:   Date?
    private var sessionPcmData:    Data?

    /// Auto-retry state for mid-recording ASR disconnects.
    private var autoRetryInProgress = false
    private var midRetryFailed = false
    private var retryCount = 0
    /// True once the ASR session has reached `onReady` at least once. Used to
    /// distinguish a server-side connection drop (retry) from a real connect-phase
    /// failure (don't retry, or back off harder).
    private var sessionWasReady = false
    private static let maxAutoRetries = 2

    /// Thread-safe routing: audio render thread reads this to forward PCM.
    private let audioClientLock = NSLock()
    private var audioTargetClient: ASRClient?

    /// Context captured at recording start (non-blocking, resolved before commit).
    private var capturedContext: PostprocessContext?

    /// ASR language for current session (used for LLM model selection).
    private var currentAsrLanguage: String?

    /// Avoid running background warm-up more than once per process (mic indicator + I/O).
    private var didRunPipelineWarmup = false

    // MARK: - Silence auto-stop

    /// Normalized audio level threshold below which we consider "silence".
    /// AudioEngine returns level = rms / 6000, clamped to 0–1.
    /// 0.01 ≈ RMS 60, well below speech but above digital zero.
    private static let silenceLevelThreshold: Float = 0.01

    /// How long continuous silence must last before auto-stopping (seconds).
    private static let silenceAutoStopSeconds: TimeInterval = 180  // 3 minutes

    /// Timestamp of the last audio frame that exceeded the silence threshold.
    private var lastVoiceTime: Date?

    // MARK: - Init

    private init() {
        audioEngine.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.handleAudioConfigurationChange()
        }
        audioEngine.onDeviceListChanged = {
            NotificationCenter.default.post(name: .audioDeviceListChanged, object: nil)
        }
    }

    /// Called on main thread when audio hardware changes (Bluetooth connect/disconnect).
    /// If recording, abort gracefully. If idle, engine already reset itself.
    private func handleAudioConfigurationChange() {
        recLog("handleAudioConfigurationChange() — state=\(state)")
        guard state == .recording || state == .finalizing else { return }

        recLog("handleAudioConfigurationChange() — aborting active session")
        swapAudioTarget(nil)
        audioEngine.stop()
        _ = audioEngine.drainBuffer()
        asrClient?.close()
        asrClient = nil
        if ConfigStore.shared.muteSystemDuringRecording { AudioController.restoreSystem() }

        SoundEffects.playError()
        errorMessage = "Audio device changed — recording stopped"
        flashBubbleError()
        state = .idle
        currentActionId = nil
        currentRecordingId = nil
        sessionPcmData = nil
        audioLevel = 0
        liveText = ""
        autoRetryInProgress = false
        midRetryFailed = false
        swapAudioTarget(nil)
    }

    // MARK: - Thread-safe audio routing

    /// Called from the audio render thread. Routes PCM to the active ASR client.
    private func sendAudioToActiveClient(_ data: Data) {
        audioClientLock.lock()
        let target = audioTargetClient
        audioClientLock.unlock()
        target?.sendAudio(data)
    }

    /// Swap the ASR client that receives audio (thread-safe for the render thread).
    private func swapAudioTarget(_ newClient: ASRClient?) {
        audioClientLock.lock()
        audioTargetClient = newClient
        audioClientLock.unlock()
    }

    // MARK: - Device switch (called from Settings)

    /// Switch the standby engine to a new device. Only when not recording.
    func switchAudioDevice(to deviceUID: String?) {
        guard state == .idle else {
            recLog("switchAudioDevice() — busy (state=\(state)), skipping")
            return
        }
        recLog("switchAudioDevice() — switching to \(deviceUID ?? "system-default")")
        audioEngine.switchDevice(to: deviceUID)
    }

    // MARK: - Key event entry points (called by HotkeySystem)

    func handleKeyPress(actionId: String = "dictation") async {
        recLog("handleKeyPress() — state=\(state), actionId=\(actionId)")
        CrashLogger.log("RecordingCoordinator", "handleKeyPress state=\(state) actionId=\(actionId) currentActionId=\(currentActionId ?? "nil")")
        guard state == .idle else { return }
        currentActionId = actionId
        await startSession()
    }

    /// Upgrade the action mode mid-recording (e.g. dictation → translate).
    /// Called by HotkeySystem when a prefix shortcut is extended within the grace window.
    func upgradeActionId(_ newActionId: String) {
        guard state == .recording else {
            recLog("upgradeActionId() — IGNORED, not recording (state=\(state))")
            CrashLogger.log("RecordingCoordinator", "upgradeActionId IGNORED — state=\(state)")
            return
        }
        let old = currentActionId ?? "dictation"
        guard newActionId != old else {
            recLog("upgradeActionId() — IGNORED, already \(newActionId)")
            return
        }
        currentActionId = newActionId
        recLog("upgradeActionId() — \(old) → \(newActionId)")
        CrashLogger.log("RecordingCoordinator", "upgradeActionId SUCCESS — \(old) → \(newActionId)")
    }

    /// After login + permissions, pre-warm TLS to the API host and run one mic start/stop so FN is responsive.
    func schedulePipelineWarmup() {
        guard !didRunPipelineWarmup else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await performPipelineWarmupIfNeeded()
        }
    }

    private func performPipelineWarmupIfNeeded() async {
        guard !didRunPipelineWarmup else { return }
        guard state == .idle else { return }
        guard let token = try? await AuthManager.shared.getValidToken() else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }

        await warmUpNetworkBestEffort(token: token)

        guard state == .idle, !audioEngine.isRunning else { return }
        do {
            try audioEngine.warmUp(deviceUID: ConfigStore.shared.selectedMicrophoneId)
            recLog("performPipelineWarmupIfNeeded — audio warm-up ok")
        } catch {
            recLog("performPipelineWarmupIfNeeded — audio warm-up: \(error.localizedDescription)")
        }
        didRunPipelineWarmup = true
    }

    private func warmUpNetworkBestEffort(token: String) async {
        let base = asrBaseURL
        guard let url = URL(string: base) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            _ = try await URLSession.shared.data(for: req)
        } catch {
            recLog("warmUpNetworkBestEffort — \(error.localizedDescription)")
        }
    }

    func handleKeyRelease() async {
        recLog("handleKeyRelease() — state=\(state), currentActionId=\(currentActionId ?? "nil")")
        CrashLogger.log("RecordingCoordinator", "handleKeyRelease state=\(state) currentActionId=\(currentActionId ?? "nil")")
        guard state == .recording else { return }
        await stopSession()
    }

    // MARK: - Session lifecycle

    private func startSession() async {
        guard let token = try? await AuthManager.shared.getValidToken() else {
            recLog("startSession() — NOT AUTHENTICATED, navigating to login")
            NotificationCenter.default.post(name: .navigateToAuth, object: nil)
            bringMainWindowToFront()
            return
        }

        let usage = UsageManager.shared
        if usage.asrCharacters.limit > 0 && usage.asrCharacters.remaining <= 0 {
            recLog("startSession() — QUOTA EXCEEDED (characters), aborting")
            errorMessage = "Weekly ASR quota exceeded. Resets \(usage.resetLabel)."
            SoundEffects.playError()
            bringMainWindowToFront()
            return
        }
        if usage.asrDuration.limit > 0 && usage.asrDuration.remaining <= 0 {
            recLog("startSession() — QUOTA EXCEEDED (duration), aborting")
            errorMessage = "Weekly ASR duration exceeded. Resets \(usage.resetLabel)."
            SoundEffects.playError()
            bringMainWindowToFront()
            return
        }

        // Play start sound BEFORE engine.start().
        // At this point BT is still in A2DP (high quality output), so sound plays clearly.
        // After the sound, engine.start() triggers A2DP→HFP switch for mic input.
        SoundEffects.playStart()

        state          = .recording
        currentRecordingId = UUID().uuidString
        recordingStart = Date()
        firstPacketTime = nil
        liveText       = ""
        errorMessage   = nil
        sessionPcmData = nil
        retryCount     = 0
        autoRetryInProgress = false
        midRetryFailed = false
        sessionWasReady = false
        lastVoiceTime  = Date()  // assume voice at start; silence timer begins from here
        recLog("startSession() — state=recording, recordingId=\(currentRecordingId ?? "nil"), actionId=\(currentActionId ?? "nil")")

        let config = ConfigStore.shared
        let vocabularyId = IdentityManager.shared.activeVocabularyId

        let userHotwords = HotwordsStore.shared.hotwords.map(\.text)
        let activeIdentityId = IdentityManager.shared.activeIdentityId

        let asrConfig = ASRSessionConfig(
            language:          config.asrLanguage,
            sampleRate:        16_000,
            format:            "pcm",
            vocabularyId:      vocabularyId,
            hotwords:          userHotwords.isEmpty ? nil : userHotwords,
            identityId:        activeIdentityId,
            recordingId:       currentRecordingId,
            retranscribe:      nil
        )

        if config.muteSystemDuringRecording { AudioController.muteSystem() }

        let client = ASRClient()
        asrClient  = client
        swapAudioTarget(client)

        client.onReady = { [weak self] in
            recLog("startSession() — ASR session ready (upstream connected)")
            Task { @MainActor in self?.sessionWasReady = true }
        }

        client.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            if self.firstPacketTime == nil { self.firstPacketTime = Date() }
            self.liveText = text
        }

        client.onDisconnect = { [weak self] error in
            guard let self, self.state == .recording || self.state == .finalizing else { return }
            let nsError = error as NSError
            recLog("onDisconnect — domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            Task { @MainActor in
                await self.handleMidRecordingDisconnect()
            }
        }

        let baseURL = asrBaseURL
        recLog("startSession() — connecting ASR to \(baseURL)")
        client.connect(token: token, baseURL: baseURL)
        client.sendStart(config: asrConfig)

        audioEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.state == .recording else { return }
                self.audioLevel = level

                // Silence auto-stop: track last time we heard voice
                if level >= Self.silenceLevelThreshold {
                    self.lastVoiceTime = Date()
                } else if let lastVoice = self.lastVoiceTime,
                          Date().timeIntervalSince(lastVoice) >= Self.silenceAutoStopSeconds {
                    recLog("silence auto-stop — \(Self.silenceAutoStopSeconds)s silence detected, stopping")
                    await self.stopDueToSilence()
                }
            }
        }

        // Brief pause to let the "Tink" sound play out before engine.start()
        // triggers BT A2DP→HFP codec switch (which disrupts audio output).
        try? await Task.sleep(nanoseconds: 120_000_000) // 120ms

        // Start PCM buffering for WAV file persistence
        audioEngine.startBuffering()

        do {
            let deviceUID = config.selectedMicrophoneId
            let actualUID = try audioEngine.start(deviceUID: deviceUID) { [weak self] data in
                self?.sendAudioToActiveClient(data)
            }
            if let requested = deviceUID, !requested.isEmpty, actualUID == nil {
                recLog("startSession() — selected device offline (\(requested)), using system default")
            }
            recLog("startSession() — audio engine started, device=\(actualUID ?? "system-default")")
        } catch let error as AudioEngineError {
            recLog("startSession() — audio engine FAILED: \(error)")
            state = .idle
            currentRecordingId = nil
            client.close()
            asrClient = nil
            if config.muteSystemDuringRecording { AudioController.restoreSystem() }

            // Permission error: redirect to permissions page
            if case .notAuthorized = error {
                errorMessage = "Microphone access required"
                NotificationCenter.default.post(name: .navigateToPermissions, object: nil)
            } else {
                errorMessage = error.localizedDescription
                flashBubbleError()
            }
            return
        } catch {
            recLog("startSession() — audio engine FAILED: \(error)")
            state = .idle
            currentRecordingId = nil
            client.close()
            asrClient = nil
            if config.muteSystemDuringRecording { AudioController.restoreSystem() }
            errorMessage = error.localizedDescription
            flashBubbleError()
            return
        }

        capturedContext = nil
    }

    // MARK: - Silence auto-stop handler

    /// Called when continuous silence exceeds the threshold. Performs a normal stop
    /// and posts a notification so the main window can show a dismissable banner.
    private func stopDueToSilence() async {
        guard state == .recording else { return }
        recLog("stopDueToSilence() — initiating normal stop after \(Self.silenceAutoStopSeconds)s silence")
        await stopSession()
        NotificationCenter.default.post(name: .recordingStoppedDueToSilence, object: nil)
    }

    /// Collect frontmost app context via ContextBridge (AX calls, runs on main).
    private func collectContext() -> PostprocessContext? {
        let app = ContextBridge.getFocusedAppInfo()
        let windowTitle = ContextBridge.getWindowTitle()
        let selectedText = ContextBridge.getSelectedText()
        let web = ContextBridge.getWebInfo()

        guard app != nil || windowTitle != nil || selectedText != nil else { return nil }

        return PostprocessContext(
            appName:      app?.name,
            bundleId:     app?.bundleId,
            windowTitle:  windowTitle,
            url:          web?.url,
            selectedText: selectedText
        )
    }

    // Silence detection thresholds (matching web RecordingConfig.silence)
    private static let silenceCheckMaxDuration: TimeInterval = 0.800
    private static let silenceRMSThreshold: Double = 100.0

    private func stopSession() async {
        // If auto-retry is actively reconnecting, wait briefly then proceed.
        if autoRetryInProgress {
            recLog("stopSession() — autoRetryInProgress, waiting briefly")
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            autoRetryInProgress = false
        }

        let start         = recordingStart ?? Date()
        let recordingEnd  = Date()
        let duration      = recordingEnd.timeIntervalSince(start)
        recLog("stopSession() — duration=\(String(format: "%.3f", duration))s (mic session; excludes ASR wait / LLM)")

        if duration < 0.200 {
            recLog("stopSession() — MISTOUCH (<200ms), discarding")
            swapAudioTarget(nil)
            audioEngine.stop()
            _ = audioEngine.drainBuffer()
            asrClient?.close()
            asrClient = nil
            if ConfigStore.shared.muteSystemDuringRecording { AudioController.restoreSystem() }
            state = .idle
            currentActionId = nil
            currentRecordingId = nil
            return
        }

        // Brief delay to capture trailing audio after key release.
        // Audio callback continues sending directly via sendAudio() during this window.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Detach audio target before stopping — prevents race with render thread.
        swapAudioTarget(nil)
        audioEngine.stop()
        let remainingAudio = audioEngine.drainBuffer()

        sessionPcmData = remainingAudio
        audioLevel = 0
        SoundEffects.playStop()

        if ConfigStore.shared.muteSystemDuringRecording { AudioController.restoreSystem() }

        // Silence detection for short recordings (ported from web):
        // discard if the user pressed the key but didn't speak.
        if duration < Self.silenceCheckMaxDuration, let pcm = sessionPcmData, !pcm.isEmpty {
            let rms = Self.computePCMRMS(pcm)
            recLog("stopSession() — short recording silence check: duration=\(String(format: "%.0f", duration * 1000))ms, RMS=\(String(format: "%.1f", rms))")
            if rms < Self.silenceRMSThreshold {
                recLog("stopSession() — SILENCE (RMS=\(String(format: "%.1f", rms)) < \(Self.silenceRMSThreshold)), discarding")
                asrClient?.close()
                asrClient = nil
                sessionPcmData = nil
                state = .idle
                currentActionId = nil
                currentRecordingId = nil
                return
            }
        }

        // If mid-recording retry failed (or no client), try post-recording retranscription
        guard let client = asrClient, !midRetryFailed else {
            recLog("stopSession() — no client or midRetryFailed=\(midRetryFailed), attempting post-recording retranscription")
            swapAudioTarget(nil)
            asrClient?.close()
            asrClient = nil
            state = .finalizing

            capturedContext = collectContext()
            await attemptPostRecordingRetranscribe(start: start, recordingEnd: recordingEnd)
            return
        }

        recLog("stopSession() — sending finish")
        client.sendFinish()
        state = .finalizing
        recLog("stopSession() — state=finalizing, waiting for ASR final...")

        capturedContext = collectContext()
        recLog("stopSession() — context captured: app=\(capturedContext?.appName ?? "nil"), selectedText=\(capturedContext?.selectedText?.prefix(40) ?? "nil")")

        // Dynamic final timeout: short recordings need 15s base; longer recordings
        // (and especially ones that hit a mid-recording reconnect + replay) need
        // headroom for upstream ASR to drain the buffered audio before emitting final.
        let finalTimeout = Self.computeFinalTimeout(duration: duration, didRetry: retryCount > 0)
        recLog("stopSession() — waiting for ASR final, timeout=\(String(format: "%.1f", finalTimeout))s (duration=\(String(format: "%.1f", duration))s, retries=\(retryCount))")

        do {
            let text = try await client.waitForFinal(timeout: finalTimeout)
            recLog("stopSession() — ASR final text=\(text.prefix(100))")

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let zeroResults = client.isLastResultLikelyServiceError
                let isServiceError = zeroResults && duration >= 3.0
                recLog("stopSession() — empty text, zeroResults=\(zeroResults), duration=\(String(format: "%.1f", duration))s, isServiceError=\(isServiceError), resultEventsCount=\(client.resultEventsCount)")
                await saveEmptyRecord(start: start, recordingEnd: recordingEnd, client: client, isServiceError: isServiceError)
            } else {
                await commitResult(text: text, start: start, recordingEnd: recordingEnd, client: client)
            }
        } catch {
            let nsErr = error as NSError
            recLog("stopSession() — ASR final FAILED: domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription)")
            if let err = error as? ASRClientError, err == .connectionFailed {
                asrClient?.close()
                asrClient = nil
                state = .idle
                currentActionId = nil
                currentRecordingId = nil
            } else {
                recLog("stopSession() — attempting post-recording retranscribe as fallback")
                asrClient?.close()
                asrClient = nil
                await attemptPostRecordingRetranscribe(start: start, recordingEnd: recordingEnd)
            }
        }
    }

    // MARK: - Post-recording retranscription fallback

    private func attemptPostRecordingRetranscribe(start: Date, recordingEnd: Date) async {
        guard let pcmData = sessionPcmData, !pcmData.isEmpty else {
            recLog("attemptPostRecordingRetranscribe() — no PCM data, saving service error")
            let dummyClient = ASRClient()
            await saveEmptyRecord(start: start, recordingEnd: recordingEnd, client: dummyClient, isServiceError: true)
            return
        }

        recLog("attemptPostRecordingRetranscribe() — retranscribing \(pcmData.count) bytes via RetranscribeService")

        do {
            _ = try await AuthManager.shared.getValidToken()
        } catch {
            recLog("attemptPostRecordingRetranscribe() — token refresh failed: \(error)")
        }

        do {
            let text = try await RetranscribeService.transcribeFromPCM(
                pcmData: pcmData,
                config: ConfigStore.shared,
                recordingId: currentRecordingId
            )
            recLog("attemptPostRecordingRetranscribe() — success: \(text.prefix(100))")

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recLog("attemptPostRecordingRetranscribe() — empty text")
                let dummyClient = ASRClient()
                await saveEmptyRecord(start: start, recordingEnd: recordingEnd, client: dummyClient, isServiceError: false)
            } else {
                let dummyClient = ASRClient()
                await commitResult(text: text, start: start, recordingEnd: recordingEnd, client: dummyClient)
            }
        } catch {
            recLog("attemptPostRecordingRetranscribe() — FAILED: \(error)")
            let dummyClient = ASRClient()
            await saveEmptyRecord(start: start, recordingEnd: recordingEnd, client: dummyClient, isServiceError: true)
        }
    }

    // MARK: - Auto-retry on mid-recording disconnect (silent reconnect, mic stays active)

    private func handleMidRecordingDisconnect() async {
        let elapsed = recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        // Allow retry when the previous session reached onReady — that means the
        // upstream connection was healthy and the drop is a server-side issue,
        // not a connect-phase failure. The 2s floor only applies before onReady.
        guard state == .recording, (sessionWasReady || elapsed >= 2.0) else {
            recLog("handleMidRecordingDisconnect() — too early (\(String(format: "%.1f", elapsed))s) and not yet ready, ignoring")
            return
        }

        guard retryCount < Self.maxAutoRetries else {
            recLog("handleMidRecordingDisconnect() — max retries (\(Self.maxAutoRetries)) reached, marking midRetryFailed")
            autoRetryInProgress = false
            midRetryFailed = true
            return
        }

        autoRetryInProgress = true
        retryCount += 1
        recLog("handleMidRecordingDisconnect() — silent retry #\(retryCount), mic stays active")

        // Detach audio from the dead client immediately
        swapAudioTarget(nil)
        asrClient?.close()
        asrClient = nil

        // Snapshot buffered PCM (non-destructive: recording continues accumulating)
        let bufferedPCM = audioEngine.snapshotBuffer()
        recLog("handleMidRecordingDisconnect() — snapshot \(bufferedPCM.count) bytes")

        // Ensure token is valid
        var token: String
        do {
            token = try await AuthManager.shared.getValidToken()
        } catch {
            recLog("handleMidRecordingDisconnect() — token refresh failed: \(error)")
            autoRetryInProgress = false
            midRetryFailed = true
            return
        }

        // Build a fresh ASR config
        let config = ConfigStore.shared
        let vocabularyId = IdentityManager.shared.activeVocabularyId
        let userHotwords = HotwordsStore.shared.hotwords.map(\.text)
        let activeIdentityId = IdentityManager.shared.activeIdentityId

        let asrConfig = ASRSessionConfig(
            language:     config.asrLanguage,
            sampleRate:   16_000,
            format:       "pcm",
            vocabularyId: vocabularyId,
            hotwords:     userHotwords.isEmpty ? nil : userHotwords,
            identityId:   activeIdentityId,
            recordingId:  currentRecordingId,
            retranscribe: nil
        )

        // Create new client and wire up callbacks
        let newClient = ASRClient()
        asrClient = newClient

        newClient.onReady = { [weak self] in
            recLog("handleMidRecordingDisconnect() — retry client ready")
            guard let self else { return }
            Task { @MainActor in
                self.autoRetryInProgress = false
                self.sessionWasReady = true
            }
        }

        newClient.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            self.liveText = text
        }

        newClient.onDisconnect = { [weak self] error in
            guard let self, self.state == .recording else { return }
            let nsError = error as NSError
            recLog("handleMidRecordingDisconnect() — retry client also disconnected: domain=\(nsError.domain) code=\(nsError.code)")
            Task { @MainActor in
                await self.handleMidRecordingDisconnect()
            }
        }

        // Clear stale text — will rebuild from new transcription
        liveText = ""

        let baseURL = asrBaseURL
        recLog("handleMidRecordingDisconnect() — connecting new ASR client to \(baseURL)")
        newClient.connect(token: token, baseURL: baseURL)
        newClient.sendStart(config: asrConfig)

        // Route live audio to the new client
        swapAudioTarget(newClient)

        // Replay buffered PCM so the new session catches up
        if !bufferedPCM.isEmpty {
            let chunkSize = 3200 // 100ms of 16kHz mono Int16
            var offset = 0
            while offset < bufferedPCM.count {
                let end = min(offset + chunkSize, bufferedPCM.count)
                let chunk = bufferedPCM.subdata(in: offset..<end)
                newClient.sendAudio(chunk)
                offset = end
            }
            recLog("handleMidRecordingDisconnect() — replayed \(bufferedPCM.count) bytes in \(offset / chunkSize) chunks")
        }
    }

    /// Marker stored in rawTranscribeContent for service errors (retranscribable).
    static let asrServiceErrorMarker = "__ASR_SERVICE_ERROR__"

    /// Save a record for empty/failed ASR results with proper error categorization.
    private func saveEmptyRecord(start: Date, recordingEnd: Date, client: ASRClient, isServiceError: Bool) async {
        let mode = ConfigStore.shared.recordingMode
        let actionId = currentActionId ?? "dictation"

        let content = isServiceError ? "[ASR service error]" : "[No speech detected]"
        let rawContent = isServiceError ? Self.asrServiceErrorMarker : ""

        // Save WAV file (needed for retranscribe if service error)
        var audioFilePath = ""
        if let pcmData = sessionPcmData, !pcmData.isEmpty {
            Task.detached {
                if let path = AudioFileService.saveWav(pcmData: pcmData, startTime: start, endTime: recordingEnd) {
                    recLog("saveEmptyRecord() — WAV saved: \(path)")
                }
            }
            audioFilePath = AudioFileService.expectedPath(startTime: start, endTime: recordingEnd)
        }
        sessionPcmData = nil

        let dbContext = ModelContext(XisperApp.modelContainer)
        let record = TranscribeRecord(
            id:                   currentRecordingId ?? UUID().uuidString,
            recordingStartTime:   start,
            recordingEndTime:     recordingEnd,
            audioFilePath:        audioFilePath,
            transcribeMethod:     "ASR_PROXY",
            transcribeContent:    content,
            rawTranscribeContent: rawContent,
            firstPacketTime:      firstPacketTime ?? recordingEnd,
            vadConfirmTime:       recordingEnd,
            recordingMode:        mode,
            actionId:             actionId
        )
        dbContext.insert(record)
        try? dbContext.save()

        recLog("saveEmptyRecord() — saved \(isServiceError ? "service error" : "no speech") record, recordingId=\(record.id)")

        client.close()
        asrClient = nil
        state = .idle
        currentActionId = nil
        currentRecordingId = nil

        if isServiceError {
            errorMessage = "ASR service error — you can retry from History"
            SoundEffects.playError()
            flashBubbleError()
        }
    }

    private static let llmPostprocessTimeoutNs: UInt64 = 8_000_000_000 // 8s

    private func commitResult(text: String, start: Date, recordingEnd: Date, client: ASRClient) async {
        state = .committing
        let actionId = currentActionId ?? "dictation"
        let isTranslateMode = actionId == "translate"
        recLog("commitResult() — state=committing, actionId=\(actionId), currentActionId=\(currentActionId ?? "nil"), rawText=\(text.prefix(80))")
        CrashLogger.log("RecordingCoordinator", "commitResult START — actionId=\(actionId) isTranslateMode=\(isTranslateMode)")

        let recordingDuration = recordingEnd.timeIntervalSince(start)
        let mode              = ConfigStore.shared.recordingMode

        let itnText = InverseTextNormalizer.normalize(text)

        // LLM postprocess: translation or dictation mode
        var finalText = itnText
        let ctx = capturedContext
        capturedContext = nil

        let meaningfulCount = itnText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }.count
        if meaningfulCount >= 4 {
            let corrections = IdentityManager.shared.activeCorrections
            let userHotwords = HotwordsStore.shared.hotwords.map(\.text)
            let identityHotwords = IdentityManager.shared.activeHotwordTexts
            let allHotwords = Array(Set(userHotwords + identityHotwords))
            let identityLabel = IdentityManager.shared.activeLabel
            let identityDesc = IdentityManager.shared.activeDescription

            if isTranslateMode {
                recLog("commitResult() — starting LLM translation")
                let instruction = TranslateSettings.shared.getTranslationInstruction()
                do {
                    finalText = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await LLMPostprocessClient.process(
                                rawText: itnText,
                                context: ctx,
                                corrections: corrections.isEmpty ? nil : corrections,
                                hotwords: allHotwords.isEmpty ? nil : allHotwords,
                                voiceMode: "translation",
                                translationInstruction: instruction,
                                speechLanguage: self.currentAsrLanguage,
                                identityContext: identityLabel != nil ? "\(identityLabel!)\(identityDesc.map { " — \($0)" } ?? "")" : nil,
                                identityId: IdentityManager.shared.activeIdentityId
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: Self.llmPostprocessTimeoutNs)
                            throw LLMPostprocessError.disabled
                        }
                        guard let result = try await group.next() else { return itnText }
                        group.cancelAll()
                        return result
                    }
                    recLog("commitResult() — LLM translation done: \(finalText.prefix(80))")
                } catch {
                    recLog("commitResult() — LLM translation failed/timeout: \(error), using ITN text")
                    finalText = itnText
                }
            } else {
                recLog("commitResult() — starting LLM postprocess")
                do {
                    finalText = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await LLMPostprocessClient.process(
                                rawText: itnText,
                                context: ctx,
                                corrections: corrections.isEmpty ? nil : corrections,
                                hotwords: allHotwords.isEmpty ? nil : allHotwords,
                                speechLanguage: self.currentAsrLanguage,
                                identityContext: identityLabel != nil ? "\(identityLabel!)\(identityDesc.map { " — \($0)" } ?? "")" : nil,
                                identityId: IdentityManager.shared.activeIdentityId
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: Self.llmPostprocessTimeoutNs)
                            throw LLMPostprocessError.disabled
                        }
                        guard let result = try await group.next() else { return itnText }
                        group.cancelAll()
                        return result
                    }
                    recLog("commitResult() — LLM postprocess done: \(finalText.prefix(80))")
                } catch {
                    recLog("commitResult() — LLM postprocess failed/timeout: \(error), using ITN text")
                    finalText = itnText
                }
            }
        }

        lastText = finalText

        // Save WAV file in background (non-blocking)
        var audioFilePath = ""
        if let pcmData = sessionPcmData, !pcmData.isEmpty {
            let wavStart = start
            let wavEnd = recordingEnd
            Task.detached {
                if let path = AudioFileService.saveWav(pcmData: pcmData, startTime: wavStart, endTime: wavEnd) {
                    recLog("commitResult() — WAV saved: \(path)")
                }
            }
            audioFilePath = AudioFileService.expectedPath(startTime: start, endTime: recordingEnd)
        }
        sessionPcmData = nil

        // Persist to SwiftData
        let dbContext = ModelContext(XisperApp.modelContainer)
        let record  = TranscribeRecord(
            id:                   currentRecordingId ?? UUID().uuidString,
            recordingStartTime:   start,
            recordingEndTime:     recordingEnd,
            audioFilePath:        audioFilePath,
            transcribeMethod:     "ASR_PROXY",
            transcribeContent:    finalText,
            rawTranscribeContent: text,
            firstPacketTime:      firstPacketTime ?? recordingEnd,
            vadConfirmTime:       recordingEnd,
            recordingMode:        mode,
            actionId:             actionId
        )
        dbContext.insert(record)
        try? dbContext.save()

        // Inject final text into the focused app
        if !finalText.isEmpty {
            recLog("commitResult() — injecting text: \(finalText.prefix(80))")
            let result = await InputWriter.write(finalText)
            recLog("commitResult() — InputWriter result=\(result)")
            if !result.success {
                errorMessage = result.error
                flashBubbleError()
            }
        } else {
            recLog("commitResult() — empty finalText, skipping injection")
        }

        // Fire webhook asynchronously (non-blocking)
        let completedAt = Date()
        let payload = WebhookPayload(
            text:          finalText,
            rawText:       text,
            timestamp:     completedAt,
            duration:      recordingDuration,
            recordingMode: mode.rawValue
        )
        Task.detached { await WebhookClient.fire(payload: payload) }

        client.close()
        asrClient = nil
        state = .idle
        recLog("commitResult() — clearing currentActionId (was: \(currentActionId ?? "nil"))")
        CrashLogger.log("RecordingCoordinator", "commitResult END — clearing currentActionId (was: \(currentActionId ?? "nil"))")
        currentActionId = nil
        currentRecordingId = nil
        recLog("commitResult() — done, state=idle")

        Task {
            recLog("commitResult() — waiting 2s before usage refresh")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            recLog("commitResult() — triggering usage refresh")
            await UsageManager.shared.refresh()
            recLog("commitResult() — usage refresh done, chars=\(UsageManager.shared.asrCharacters.used)/\(UsageManager.shared.asrCharacters.limit)")
        }
    }

    // MARK: - Bubble Error Flash

    /// Show error state in bubble for 2 seconds, then auto-dismiss.
    private func flashBubbleError() {
        showBubbleError = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            showBubbleError = false
        }
    }

    // MARK: - Helpers

    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where !(w is NSPanel) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// Compute timeout for `waitForFinal` after stopSession.
    ///
    /// 8s was the old fixed value, which caused short recordings to occasionally
    /// time out under provider load and made long recordings (especially after a
    /// mid-recording reconnect that replays buffered audio) almost always fail.
    ///
    /// Heuristic: 15s floor + 0.3s per second of audio above the first 5s.
    /// If a silent retry happened, the proxy has to drain replayed audio before
    /// emitting final, so add an extra 10s buffer.
    private static func computeFinalTimeout(duration: TimeInterval, didRetry: Bool) -> TimeInterval {
        let base: TimeInterval = 15.0
        let perSecond: TimeInterval = 0.3
        let extra = max(0, duration - 5.0) * perSecond
        let retryBuffer: TimeInterval = didRetry ? 10.0 : 0
        return base + extra + retryBuffer
    }

    /// Compute RMS of 16-bit mono little-endian PCM data (same algorithm as web computeAudioRMS).
    private static func computePCMRMS(_ data: Data) -> Double {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return 0 }
        var sumSq: Double = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let s = Double(Int16(littleEndian: samples[i]))
                sumSq += s * s
            }
        }
        return (sumSq / Double(sampleCount)).squareRoot()
    }

    private var asrBaseURL: String { AppEnvironment.serviceBaseURL }
}

// MARK: - ASRClientError Equatable

extension ASRClientError: Equatable {
    static func == (lhs: ASRClientError, rhs: ASRClientError) -> Bool {
        switch (lhs, rhs) {
        case (.connectionFailed, .connectionFailed): return true
        case (.timeout, .timeout):                   return true
        case (.serverError(let a), .serverError(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - WAV File Service

enum AudioFileService {
    private static let sampleRate:     UInt32 = 16_000
    private static let bitsPerSample:  UInt16 = 16
    private static let channels:       UInt16 = 1

    static func saveWav(pcmData: Data, startTime: Date, endTime: Date) -> String? {
        let dir = recordingsDir(for: startTime)
        let startTs = Int(startTime.timeIntervalSince1970 * 1000)
        let endTs = Int(endTime.timeIntervalSince1970 * 1000)
        let filePath = dir.appendingPathComponent("\(startTs)_\(endTs).wav")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var wav = buildWavHeader(pcmByteLength: pcmData.count)
            wav.append(pcmData)
            try wav.write(to: filePath)
            return filePath.path
        } catch {
            print("[AudioFile] Failed to save: \(error)")
            return nil
        }
    }

    /// Predict the file path without performing I/O (for DB record before async write completes).
    static func expectedPath(startTime: Date, endTime: Date) -> String {
        let dir = recordingsDir(for: startTime)
        let startTs = Int(startTime.timeIntervalSince1970 * 1000)
        let endTs = Int(endTime.timeIntervalSince1970 * 1000)
        return dir.appendingPathComponent("\(startTs)_\(endTs).wav").path
    }

    private static func recordingsDir(for date: Date) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return appSupport
            .appendingPathComponent(AppEnvironment.appSupportFolderName)
            .appendingPathComponent("recordings")
            .appendingPathComponent(formatter.string(from: date))
    }

    private static func buildWavHeader(pcmByteLength: Int) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)

        var h = Data(capacity: 44)
        h.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        h.appendLE(UInt32(36 + pcmByteLength))
        h.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        h.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        h.appendLE(UInt32(16))                          // fmt chunk size
        h.appendLE(UInt16(1))                           // PCM format
        h.appendLE(channels)
        h.appendLE(sampleRate)
        h.appendLE(byteRate)
        h.appendLE(blockAlign)
        h.appendLE(bitsPerSample)
        h.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        h.appendLE(UInt32(pcmByteLength))
        return h
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
}
