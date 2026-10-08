import Foundation

/// One request on the request socket, Hyprland's `[flags]/command args`:
/// `j/clients`, `/dispatch hl.dsp.focus({ workspace = 2 })`, or a bare
/// `clients`. The only flag is `j` (JSON output); unknown flags are ignored.
public struct IPCRequest: Equatable, Sendable {
    public var json: Bool
    public var command: String
    /// Everything after the command, with surrounding whitespace removed.
    public var arguments: String

    public init(command: String, arguments: String = "", json: Bool = false) {
        self.command = command
        self.arguments = arguments
        self.json = json
    }

    /// nil when there is no command.
    public init?(parsing text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var json = false
        // flags come before the first "/", only when that prefix is all letters
        if let slash = body.firstIndex(of: "/"), body[..<slash].allSatisfy(\.isLetter) {
            json = body[..<slash].contains("j")
            body = body[body.index(after: slash)...]
        }
        let command = body.prefix { !$0.isWhitespace }
        guard !command.isEmpty else { return nil }
        self.json = json
        self.command = String(command)
        self.arguments = body.dropFirst(command.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The wire form.
    public var encoded: String {
        let head = "\(json ? "j" : "")/\(command)"
        return arguments.isEmpty ? head : "\(head) \(arguments)"
    }
}

/// Replies to actions (dispatch, reload) are "ok" or "error: <reason>";
/// an unknown command gets Hyprland's "unknown request".
public enum IPCReply {
    public static let ok = "ok"
    public static let unknownRequest = "unknown request"

    public static func error(_ message: String) -> String { "error: \(message)" }

    /// True for a reply that reports a failure. Only actions reply
    /// "error: <reason>"; query output is never a failure, though it may
    /// start with "error: " (configerrors listing an error).
    public static func isFailure(_ reply: String, to request: IPCRequest) -> Bool {
        if reply == unknownRequest { return true }
        return ["dispatch", "reload"].contains(request.command) && reply.hasPrefix("error: ")
    }
}
