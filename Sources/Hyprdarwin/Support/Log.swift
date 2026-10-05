import Foundation
import os

/// Logs to the unified log (subsystem below), to stderr, and to
/// ~/Library/Logs/hyprdarwin.log, which is truncated at launch.
enum Log {
    static let subsystem = "io.github.brucechanjianle.hyprdarwin"
    private static let logger = Logger(subsystem: subsystem, category: "wm")
    private static let queue = DispatchQueue(label: "hyprdarwin.log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/hyprdarwin.log")

    private static let handle: FileHandle? = {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        return try? FileHandle(forWritingTo: fileURL)
    }()

    static var debugEnabled = ProcessInfo.processInfo.environment["HYPRDARWIN_DEBUG"] == "1"

    static func info(_ message: String) { write("info", message) }
    static func error(_ message: String) { write("error", message) }
    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        write("debug", message())
    }

    private static func write(_ level: String, _ message: String) {
        switch level {
        case "error": logger.error("\(message, privacy: .public)")
        case "debug": logger.debug("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            handle?.write(Data(line.utf8))
        }
    }
}
