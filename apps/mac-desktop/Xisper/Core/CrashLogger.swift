/**
 * CrashLogger
 *
 * Thread-safe debug logger for crash investigation.
 * Writes to /tmp/xisper-crash-debug.log with timestamps.
 * Use when debugging "multiple clicks" or rapid interaction crashes.
 */

import Foundation

enum CrashLogger {

    private static let logURL = URL(fileURLWithPath: "/tmp/\(AppEnvironment.crashLogFileName)")
    private static let queue = DispatchQueue(label: "xyz.hawkeye.xisper.crashlog", qos: .utility)

    /// Log a message (thread-safe, non-blocking).
    static func log(_ tag: String, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(tag)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            do {
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                let fh = try FileHandle(forWritingTo: logURL)
                defer { fh.closeFile() }
                fh.seekToEndOfFile()
                try fh.write(contentsOf: data)
            } catch {
                print("[CrashLogger] write failed: \(error)")
            }
        }
    }

    /// Log with optional error.
    static func log(_ tag: String, _ message: String, error: Error?) {
        if let e = error {
            log(tag, "\(message) — error: \(e)")
        } else {
            log(tag, message)
        }
    }
}
