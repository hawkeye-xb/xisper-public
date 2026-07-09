/**
 * SoundEffects
 *
 * Plays short audio cues for recording start/stop events.
 * Uses macOS system sounds — no bundled assets required.
 * Respects ConfigStore.enableSoundEffects toggle.
 */

import AppKit

enum SoundEffects {

    private static let startSound = NSSound(named: "Tink")
    private static let stopSound  = NSSound(named: "Pop")
    private static let errorSound = NSSound(named: "Basso")

    /// Force-load all system sounds so the first playback has no disk-IO lag.
    static func warmUp() {
        _ = startSound
        _ = stopSound
        _ = errorSound
    }

    static func playStart() {
        guard ConfigStore.shared.enableSoundEffects else { return }
        startSound?.play()
    }

    static func playStop() {
        guard ConfigStore.shared.enableSoundEffects else { return }
        stopSound?.play()
    }

    static func playError() {
        guard ConfigStore.shared.enableSoundEffects else { return }
        errorSound?.play()
    }
}
