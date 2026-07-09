/**
 * AudioEngine
 *
 * Microphone capture → 16 kHz mono Int16 PCM for ASR.
 *
 * Uses **CoreAudio AUHAL** (Hardware Abstraction Layer AudioUnit) directly,
 * NOT AVAudioEngine. This is the same approach Chrome/OBS use.
 *
 * Why not AVAudioEngine:
 *   - `inputNode.outputFormat` returns cached values after BT codec switches
 *   - `installTap(format: nil)` still uses the cached format on macOS
 *   - No reliable way to get the actual hardware format through AVAudioEngine
 *   - Known industry-wide issue: AudioKit, WhisperKit all have the same bugs
 *
 * AUHAL advantages:
 *   - Queries device format directly from hardware, no caching
 *   - No graph negotiation, no automatic reconnection attempts
 *   - Full control over device selection per-AudioUnit (not system-wide)
 *   - This is what all serious macOS audio apps use
 */

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Error

enum AudioEngineError: LocalizedError {
    case notAuthorized
    case converterCreationFailed
    case engineStartFailed(Error)
    case auhalSetupFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone access not authorized"
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .engineStartFailed(let e):
            return "Audio engine failed to start: \(e.localizedDescription)"
        case .auhalSetupFailed(let code):
            return "Audio hardware setup failed (error \(code))"
        }
    }
}

// MARK: - AudioInputDevice

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

// MARK: - AudioEngine

final class AudioEngine {

    /// Final output: 16 kHz mono Int16 PCM for ASR.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate:   16_000,
        channels:     1,
        interleaved:  true
    )!

    // ── AUHAL state ──
    private var audioUnit: AudioComponentInstance?
    /// Converts hardware format → 16 kHz Int16.
    private var converter: AVAudioConverter?
    private var inputAVFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?

    private var recording = false
    private var dataCallback: ((Data) -> Void)?

    // ── PCM buffering ──
    private let bufferLock = NSLock()
    private var pcmChunks: [Data] = []
    private var isBuffering = false

    // ── Callbacks ──
    var onAudioLevel: ((Float) -> Void)?
    var onConfigurationChange: (() -> Void)?
    var onDeviceListChanged: (() -> Void)?

    // ── Device list observer ──
    private var deviceListListenerInstalled = false
    /// Listener for default input device changes.
    private var defaultDeviceListenerInstalled = false

    var isRunning: Bool { recording }

    init() {
        observeDeviceListChange()
        observeDefaultDeviceChange()
    }

    deinit {
        destroyUnit()
        removeDeviceListListener()
        removeDefaultDeviceListener()
    }

    // MARK: - PCM Buffering

    func startBuffering() {
        bufferLock.lock()
        pcmChunks = []
        isBuffering = true
        bufferLock.unlock()
    }

    func drainBuffer() -> Data {
        bufferLock.lock()
        isBuffering = false
        let chunks = pcmChunks
        pcmChunks = []
        bufferLock.unlock()
        var combined = Data(capacity: chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { combined.append(chunk) }
        return combined
    }

    /// Copy accumulated PCM without clearing the buffer or stopping recording.
    /// Used for mid-recording retry: replay buffered audio to a new ASR connection.
    func snapshotBuffer() -> Data {
        bufferLock.lock()
        let chunks = pcmChunks
        bufferLock.unlock()
        var combined = Data(capacity: chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks { combined.append(chunk) }
        return combined
    }

    // MARK: - Warm-up

    func warmUp(deviceUID: String? = nil) throws {
        try start(deviceUID: deviceUID) { _ in }
        stop()
    }

    // MARK: - Start (AUHAL)

    @discardableResult
    func start(deviceUID: String? = nil, onAudioData: @escaping (Data) -> Void) throws -> String? {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioEngineError.notAuthorized
        }

        destroyUnit()

        // 1. Create HAL Output AudioUnit
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw AudioEngineError.auhalSetupFailed(-1)
        }
        var unit: AudioComponentInstance?
        try checkOSStatus(AudioComponentInstanceNew(component, &unit))
        guard let au = unit else { throw AudioEngineError.auhalSetupFailed(-1) }
        audioUnit = au

        // 2. Enable input (bus 1), disable output (bus 0)
        var one: UInt32 = 1
        var zero: UInt32 = 0
        try checkOSStatus(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                               kAudioUnitScope_Input, 1, &one, 4))
        try checkOSStatus(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                               kAudioUnitScope_Output, 0, &zero, 4))

        // 3. Set device
        var actualDeviceUID: String? = nil
        var deviceID: AudioDeviceID
        if let uid = deviceUID, !uid.isEmpty, let dev = Self.listInputDevices().first(where: { $0.uid == uid }) {
            deviceID = dev.id
            actualDeviceUID = uid
        } else {
            deviceID = Self.getDefaultInputDeviceID()
        }
        try checkOSStatus(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &deviceID,
                                               UInt32(MemoryLayout<AudioDeviceID>.size)))

        // 4. Get REAL hardware input format (no caching, direct from device)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Input, 1, &asbd, &asbdSize))

        // 5. Set output format on bus 1 to match input (no conversion in AUHAL)
        try checkOSStatus(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Output, 1, &asbd, asbdSize))

        // 6. Create AVAudioFormat + converters
        guard let inputFmt = AVAudioFormat(streamDescription: &asbd) else {
            destroyUnit()
            throw AudioEngineError.converterCreationFailed
        }
        self.inputAVFormat = inputFmt

        guard let conv = AVAudioConverter(from: inputFmt, to: targetFormat) else {
            destroyUnit()
            throw AudioEngineError.converterCreationFailed
        }
        self.converter = conv

        // 7. Pre-allocate render buffer (enough for max frames per callback)
        var maxFrames: UInt32 = 4096
        try checkOSStatus(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
                                               kAudioUnitScope_Global, 0, &maxFrames, 4))
        renderBuffer = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: maxFrames)

        // 8. Set input callback
        self.dataCallback = onAudioData
        var callbackStruct = AURenderCallbackStruct(
            inputProc: auhalInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try checkOSStatus(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                               kAudioUnitScope_Global, 0, &callbackStruct,
                                               UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        // 9. Initialize + start
        try checkOSStatus(AudioUnitInitialize(au))
        try checkOSStatus(AudioOutputUnitStart(au))

        recording = true
        return actualDeviceUID
    }

    // MARK: - Stop

    func stop() {
        if let au = audioUnit, recording {
            AudioOutputUnitStop(au)
        }
        recording = false
        dataCallback = nil
        onAudioLevel = nil
        destroyUnit()
    }

    // MARK: - Device switch (no-op, fresh unit per recording)

    func switchDevice(to deviceUID: String?) {
        // No persistent state — device is set in start().
    }

    // MARK: - Device Enumeration

    static func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { deviceID -> AudioInputDevice? in
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }

            let layout = UnsafeMutablePointer<AudioBufferList>.allocate(
                capacity: Int(streamSize) / MemoryLayout<AudioBufferList>.stride + 1
            )
            defer { layout.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &streamAddr, 0, nil, &streamSize, layout) == noErr
            else { return nil }

            let bufferList = UnsafeMutableAudioBufferListPointer(layout)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { return nil }

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
                  let uid = uidRef?.takeRetainedValue() as String?
            else { return nil }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef) == noErr,
                  let name = nameRef?.takeRetainedValue() as String?
            else { return nil }

            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    static func isDeviceOnline(uid: String) -> Bool {
        listInputDevices().contains { $0.uid == uid }
    }

    static func getDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    // MARK: - Private — AUHAL lifecycle

    private func destroyUnit() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        audioUnit = nil
        converter = nil
        inputAVFormat = nil
        renderBuffer = nil
    }

    private func checkOSStatus(_ status: OSStatus) throws {
        guard status == noErr else {
            destroyUnit()
            throw AudioEngineError.auhalSetupFailed(status)
        }
    }

    // MARK: - Private — Audio processing (called from AUHAL render thread)

    fileprivate func handleInputBuffer(
        _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
        _ inNumberFrames: UInt32
    ) {
        guard let au = audioUnit,
              let buffer = renderBuffer,
              let callback = dataCallback,
              let conv = converter else { return }

        // Reset buffer for this render cycle.
        buffer.frameLength = inNumberFrames

        // Pull audio from hardware into our buffer.
        let bufferListPtr = buffer.mutableAudioBufferList
        let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1,
                                     inNumberFrames, bufferListPtr)
        guard status == noErr else { return }

        // Convert hardware format → 16 kHz Int16
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inNumberFrames) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outputCapacity
        ) else { return }

        var inputConsumed = false
        var convError: NSError?
        conv.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard convError == nil, outputBuffer.frameLength > 0,
              let ch = outputBuffer.int16ChannelData else { return }

        let frameCount = Int(outputBuffer.frameLength)
        let int16Ptr = UnsafePointer(ch[0])
        let data = Data(bytes: int16Ptr, count: frameCount * MemoryLayout<Int16>.size)

        callback(data)

        bufferLock.lock()
        if isBuffering { pcmChunks.append(data) }
        bufferLock.unlock()

        if let levelCb = onAudioLevel, frameCount > 0 {
            var sumSq: Float = 0
            for i in 0..<frameCount {
                let s = Float(int16Ptr[i])
                sumSq += s * s
            }
            let rms = sqrtf(sumSq / Float(frameCount))
            let level = min(rms / 6000.0, 1.0)
            levelCb(level)
        }
    }

    // MARK: - Private — Device change observers

    private func observeDeviceListChange() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            self?.onDeviceListChanged?()
        }
        deviceListListenerInstalled = (status == noErr)
    }

    private func observeDefaultDeviceChange() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self, self.recording, let callback = self.dataCallback else { return }

            // Default input device changed mid-recording.
            // Try seamless reconnect: destroy old unit → create new for new default → continue.
            self.destroyUnit()
            self.recording = false

            do {
                try self.start(onAudioData: callback)
                // Reconnected — recording continues with new device.
            } catch {
                // Can't reconnect — notify coordinator to handle the interrupted session.
                self.dataCallback = nil
                self.onAudioLevel = nil
                self.onConfigurationChange?()
            }
        }
        defaultDeviceListenerInstalled = (status == noErr)
    }

    private func removeDeviceListListener() {
        guard deviceListListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in }
    }

    private func removeDefaultDeviceListener() {
        guard defaultDeviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { _, _ in }
    }
}

// MARK: - AUHAL C Callback (free function, called on audio render thread)

private func auhalInputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    engine.handleInputBuffer(ioActionFlags, inTimeStamp, inNumberFrames)
    return noErr
}
