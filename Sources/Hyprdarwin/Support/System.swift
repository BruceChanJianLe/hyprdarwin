import AppKit
import HyprdarwinCore
import HyprdarwinIPC

enum Monitors {
    /// NSScreen geometry flipped into the global top-left space AX uses.
    /// The primary display (the one with the menu bar) comes first.
    static func current() -> [Monitor] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        func flip(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Monitor(id: id, name: screen.localizedName, frame: flip(screen.frame), visibleFrame: flip(screen.visibleFrame))
        }
    }
}

enum Exec {
    /// Run `command` with /bin/sh, detached from hyprdarwin's own I/O.
    static func run(_ command: String, environment extra: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        // apps started from Finder get a bare PATH; add the usual tool locations
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let missing = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) }
        environment["PATH"] = (missing + [path]).joined(separator: ":")
        // set by IPCService once the sockets are up (read live: setenv
        // after launch is not always in ProcessInfo's copy)
        if let signature = getenv(IPCPaths.signatureVariable) {
            environment[IPCPaths.signatureVariable] = String(cString: signature)
        }
        environment.merge(extra) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            Log.info("exec: \(command)")
        } catch {
            Log.error("exec failed for \"\(command)\": \(error.localizedDescription)")
        }
    }
}

enum WindowStack {
    /// Every window the window server has on screen, with its owner and
    /// layer. Needs no permission.
    static func onScreenWindows() -> [WindowID: ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var windows: [WindowID: ScreenWindow] = [:]
        for entry in list {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            windows[id] = ScreenWindow(pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0)
        }
        return windows
    }

    /// The window number of the front-most window under `point`, or nil when
    /// something above the normal window layer (a menu, a panel, the Dock,
    /// Spotlight) covers it. Needs no screen-recording permission: only
    /// bounds, layer and number are read.
    static func topmostNormalWindow(at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in list {
            // hyprdarwin's own border panels are not windows to focus
            if (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point) else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.01 { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
