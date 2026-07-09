import Foundation
import SwiftData

// MARK: - RecordingMode

enum RecordingMode: String, Codable, CaseIterable {
    case pressHold   = "PRESS_HOLD"
    case pressToggle = "PRESS_TOGGLE"
}

// MARK: - TranscribeSegment (Codable, stored as JSON in TranscribeRecord)

struct TranscribeSegment: Codable, Identifiable {
    var id: String          // "<startTime>-<endTime>"
    var startTime: Int      // ms
    var endTime: Int        // ms
    var text: String
    var definite: Bool      // VAD-confirmed/final
    var committedAt: Date
}

// MARK: - TranscribeRecord

/// Persistent transcription session record, stored via SwiftData.
///
/// Mirrors the Electron `TranscribeRecord` schema with timestamps as `Date`
/// and segments serialised as JSON `Data`.
@Model
final class TranscribeRecord {

    @Attribute(.unique) var id: String

    var recordingStartTime: Date
    var recordingEndTime: Date
    var audioFilePath: String              // Reserved; currently empty
    var transcribeMethod: String
    var transcribeContent: String          // Final text (after postprocessing if applied)
    var rawTranscribeContent: String?      // Raw ASR text before postprocessing
    var segmentsData: Data?               // JSON-encoded [TranscribeSegment]
    var firstPacketTime: Date
    var vadConfirmTime: Date
    var recordingModeRaw: String           // RecordingMode.rawValue
    var actionId: String?                  // Hotkey that triggered this session
    var postprocessTimeMs: Int?
    var createdAt: Date

    // MARK: - Init

    init(
        id: String = UUID().uuidString,
        recordingStartTime: Date,
        recordingEndTime: Date,
        audioFilePath: String = "",
        transcribeMethod: String,
        transcribeContent: String,
        rawTranscribeContent: String? = nil,
        firstPacketTime: Date,
        vadConfirmTime: Date,
        recordingMode: RecordingMode = .pressHold,
        actionId: String? = nil,
        postprocessTimeMs: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recordingStartTime = recordingStartTime
        self.recordingEndTime = recordingEndTime
        self.audioFilePath = audioFilePath
        self.transcribeMethod = transcribeMethod
        self.transcribeContent = transcribeContent
        self.rawTranscribeContent = rawTranscribeContent
        self.firstPacketTime = firstPacketTime
        self.vadConfirmTime = vadConfirmTime
        self.recordingModeRaw = recordingMode.rawValue
        self.actionId = actionId
        self.postprocessTimeMs = postprocessTimeMs
        self.createdAt = createdAt
    }

    // MARK: - Computed

    var recordingMode: RecordingMode {
        get { RecordingMode(rawValue: recordingModeRaw) ?? .pressHold }
        set { recordingModeRaw = newValue.rawValue }
    }

    var segments: [TranscribeSegment] {
        get {
            guard let data = segmentsData else { return [] }
            return (try? JSONDecoder().decode([TranscribeSegment].self, from: data)) ?? []
        }
        set {
            segmentsData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Recording duration in seconds.
    var duration: TimeInterval {
        recordingEndTime.timeIntervalSince(recordingStartTime)
    }

    /// Time from recording start to first ASR packet.
    var firstPacketLatency: TimeInterval {
        firstPacketTime.timeIntervalSince(recordingStartTime)
    }
}
