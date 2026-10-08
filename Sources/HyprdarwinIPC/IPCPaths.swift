import Darwin
import Foundation

/// A running (or crashed) hyprdarwin's socket directory:
/// `<base>/<signature>/.socket.sock` (requests) and `.socket2.sock` (events).
public struct IPCInstance: Equatable, Sendable {
    public var signature: String
    public var directory: String

    public init(signature: String, base: String) {
        self.signature = signature
        self.directory = (base as NSString).appendingPathComponent(signature)
    }

    public var requestSocket: String { (directory as NSString).appendingPathComponent(IPCPaths.requestSocketName) }
    public var eventSocket: String { (directory as NSString).appendingPathComponent(IPCPaths.eventSocketName) }

    /// Seconds since 1970 when the instance started, from its signature.
    public var startTime: Int? { signature.split(separator: "_").first.flatMap { Int($0) } }

    public var pid: Int32? { signature.split(separator: "_").dropFirst().first.flatMap { Int32($0) } }

    /// Something accepts connections on the request socket.
    public var isLive: Bool {
        guard let fd = try? UnixSocket.connect(path: requestSocket) else { return false }
        close(fd)
        return true
    }
}

public enum IPCPaths {
    /// Exported to every process hyprdarwin starts, like Hyprland's
    /// HYPRLAND_INSTANCE_SIGNATURE.
    public static let signatureVariable = "HYPRDARWIN_INSTANCE_SIGNATURE"
    public static let requestSocketName = ".socket.sock"
    public static let eventSocketName = ".socket2.sock"

    /// `$TMPDIR/hyprdarwin`, where $TMPDIR is the per-user temporary
    /// directory macOS hands every process (read with confstr, so a shell
    /// that overrides TMPDIR still finds the app's sockets).
    public static var defaultBase: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // the length includes the terminating NUL
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temporary = length > 1 && length <= buffer.count
            ? String(decoding: buffer[0..<(length - 1)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return (temporary as NSString).appendingPathComponent("hyprdarwin")
    }

    /// `<seconds since 1970>_<pid>`: unique per launch, sorts by age.
    public static func newSignature(pid: Int32 = getpid(), date: Date = Date()) -> String {
        "\(Int(date.timeIntervalSince1970))_\(pid)"
    }

    /// Every instance directory under `base` that has a request socket,
    /// newest first. Liveness is not checked.
    public static func instances(base: String = defaultBase) -> [IPCInstance] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { IPCInstance(signature: $0, base: base) }
            .filter { FileManager.default.fileExists(atPath: $0.requestSocket) }
            .sorted { ($0.startTime ?? 0, $0.signature) > ($1.startTime ?? 0, $1.signature) }
    }

    /// The instance a client talks to: `explicit` (a signature, or an index
    /// into the live instances, newest first) must exist; otherwise the
    /// one named by `environment` when it is still live, else the newest
    /// live instance.
    public static func resolve(explicit: String?, environment: String?, base: String = defaultBase) -> Result<IPCInstance, ResolveError> {
        let live = instances(base: base).filter(\.isLive)
        if let explicit, !explicit.isEmpty {
            if let match = live.first(where: { $0.signature == explicit }) { return .success(match) }
            if let index = Int(explicit), live.indices.contains(index) { return .success(live[index]) }
            return .failure(.noSuchInstance(explicit))
        }
        if let environment, let match = live.first(where: { $0.signature == environment }) {
            return .success(match)
        }
        guard let newest = live.first else { return .failure(.notRunning(base)) }
        return .success(newest)
    }

    public enum ResolveError: Error, Equatable, CustomStringConvertible {
        case notRunning(String)
        case noSuchInstance(String)

        public var description: String {
            switch self {
            case .notRunning(let base): return "hyprdarwin is not running (no live instance in \(base))"
            case .noSuchInstance(let name): return "no running hyprdarwin instance \"\(name)\" (see hyprdarwinctl instances)"
            }
        }
    }

    /// Remove instance directories under `base` whose request socket no
    /// longer answers (their hyprdarwin crashed or was killed).
    public static func removeStaleInstances(base: String = defaultBase) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        for name in names where !name.hasPrefix(".") {
            let instance = IPCInstance(signature: name, base: base)
            if !instance.isLive { try? FileManager.default.removeItem(atPath: instance.directory) }
        }
    }
}
