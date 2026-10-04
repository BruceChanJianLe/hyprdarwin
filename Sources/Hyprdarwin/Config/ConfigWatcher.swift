import CoreServices
import Foundation
import HyprdarwinConfig

/// Finds the config file, writes the commented default on first run, and
/// watches the config's directory (not the file: editors save by renaming a
/// temp file over it, which would orphan a file watch) for changes to any
/// .lua file, debounced. Main-thread only.
final class ConfigWatcher {
    let path: String
    var directory: String { (path as NSString).deletingLastPathComponent }
    /// Called on the main thread after a debounced change.
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private static let debounce: TimeInterval = 0.15

    init(path: String = ConfigPaths.resolve()) {
        self.path = path
    }

    /// Write the default config when the file is missing. Returns true if it did.
    @discardableResult
    func createDefaultIfMissing() -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try DefaultConfig.text.write(toFile: path, atomically: true, encoding: .utf8)
            Log.info("wrote the default config to \(path)")
            return true
        } catch {
            Log.error("could not write the default config to \(path): \(error.localizedDescription)")
            return false
        }
    }

    var isWatching: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        // a symlinked config (dotfiles) is edited where the link points
        func real(_ path: String) -> String {
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let directories = Array(Set([real(directory), (real(path) as NSString).deletingLastPathComponent]))
        guard let created = FSEventStreamCreate(
            nil, configWatcherCallback, &context, directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags
        ) else {
            Log.error("could not watch \(directory)")
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        FSEventStreamStart(created)
        stream = created
        Log.info("watching \(directories.sorted().joined(separator: ", ")) for config changes")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        pending?.cancel()
    }

    fileprivate func handle(paths: [String]) {
        let configName = (path as NSString).lastPathComponent
        guard paths.contains(where: { $0.hasSuffix(".lua") || ($0 as NSString).lastPathComponent == configName }) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: item)
    }
}

private func configWatcherCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()
    let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    watcher.handle(paths: list)
}
