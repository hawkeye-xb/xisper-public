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

    private static var savedDeviceID: AudioDeviceID?
    private static var savedMuted: Bool  = false
    private static var savedVolume: Float = 1.0

    // MARK: - Public API

    /// Mute the default output device, saving its current state for restore.
    static func muteSystem() {
        guard let device = defaultOutputDevice() else { return }
        savedDeviceID = device
        savedMuted    = isMuted(device)
        savedVolume   = volume(of: device)
        setMuted(true, on: device)
    }

    /// Restore the device that was muted by `muteSystem()` to its original state.
    static func restoreSystem() {
        guard let device = savedDeviceID else { return }
        savedDeviceID = nil
        setMuted(savedMuted, on: device)
        if !savedMuted {
            setVolume(savedVolume, on: device)
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
