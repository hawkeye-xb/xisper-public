/**
 * AudioController
 *
 * System audio mute/restore via CoreAudio AudioObject API.
 * Replaces the osascript-based audio-controller.ts.
 */

import CoreAudio
import Foundation

// MARK: - AudioController

enum AudioController {

    // MARK: - Saved state (pinned to the device that was actually muted)
    //
    // Balanced mute/restore is enforced by `didMute`. All callers run on the main
    // actor (RecordingCoordinator), so this static state is accessed serially and
    // needs no locking.

    /// True while WE are holding a mute. Guards against unbalanced / double calls.
    private static var didMute = false
    /// The exact device we muted. Restored to its prior state on `restoreSystem()`,
    /// even if the system default output changed since (e.g. a Bluetooth A2DP↔HFP
    /// codec switch when the mic activates) — we must un-mute the device we touched,
    /// not whatever happens to be default at restore time.
    private static var mutedDeviceID: AudioDeviceID?
    /// The device's mute + volume BEFORE we muted it.
    private static var priorMuted: Bool  = false
    private static var priorVolume: Float = 1.0

    // MARK: - Public API

    /// Mute the default output device, saving its current state for restore.
    ///
    /// Idempotent: if we already hold a mute, this is a no-op. Without this guard a
    /// second `muteSystem()` (from an overlapping session) would capture our OWN
    /// muted state as the baseline, and the later restore would leave audio muted
    /// forever. See issue #24.
    static func muteSystem() {
        guard !didMute else { return }
        guard let device = defaultOutputDevice() else { return }
        mutedDeviceID = device
        priorMuted    = isMuted(device)
        priorVolume   = volume(of: device)
        didMute       = true
        setMuted(true, on: device)
    }

    /// Restore the device that was muted by `muteSystem()` to its original state.
    ///
    /// Idempotent: a restore with no matching mute (e.g. an early-exit start path
    /// that never reached `muteSystem()`) is a safe no-op, so it can never write a
    /// wrong state onto the device.
    static func restoreSystem() {
        guard didMute, let device = mutedDeviceID else { return }
        didMute       = false
        mutedDeviceID = nil
        setMuted(priorMuted, on: device)
        if !priorMuted {
            setVolume(priorVolume, on: device)
        }
    }

    // MARK: - Default output device

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = kAudioObjectUnknown
        var size     = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }

    // MARK: - Mute

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        var value: UInt32 = 0
        var size          = UInt32(MemoryLayout<UInt32>.size)
        var address       = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value != 0
    }

    private static func setMuted(_ muted: Bool, on device: AudioDeviceID) {
        var value: UInt32 = muted ? 1 : 0
        var address       = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
    }

    // MARK: - Volume

    private static func volume(of device: AudioDeviceID) -> Float {
        var value: Float32 = 1.0
        var size           = UInt32(MemoryLayout<Float32>.size)
        var address        = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func setVolume(_ vol: Float, on device: AudioDeviceID) {
        var value: Float32 = Float32(vol)
        var address        = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &value
        )
    }
}
