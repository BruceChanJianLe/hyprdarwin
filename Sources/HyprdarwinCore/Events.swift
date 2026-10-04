import CoreGraphics
import Foundation

/// Side effects the model asks the app to perform after a change.
public enum Effect: Equatable, Sendable {
    case exec(String)
    case close(WindowID)
    case kill(pid: Int32)
    /// Give the window OS keyboard focus and raise it.
    case focus(WindowID)
    /// Give the keyboard back to an app, managed or not: its `window` when
    /// known, else whichever window the app keys itself. Raises nothing else.
    case activate(pid: Int32, window: WindowID?)
    case warpCursor(CGPoint)
    /// The active submap changed ("" is the global map).
    case submap(String)
    case reload
    case exit
    /// A dispatcher could not run; worth a log line, not an alert.
    case failed(String)
}

/// Who has the OS keyboard: the frontmost app and, once known, its focused
/// window. Unmanaged apps and hyprdarwin itself count too.
public struct KeyboardOwner: Equatable, Sendable {
    public var pid: Int32
    public var window: WindowID?

    public init(pid: Int32, window: WindowID? = nil) {
        self.pid = pid
        self.window = window
    }
}

/// State changes, named after Hyprland's event socket events so the event
/// socket (next milestone) can stream them as `EVENT>>DATA` lines.
public enum WMEvent: Equatable, Sendable {
    case openWindow(WindowID, workspace: WorkspaceID, bundleID: String, title: String)
    case closeWindow(WindowID)
    case activeWindow(WindowID?, bundleID: String, title: String)
    case workspace(WorkspaceID)
    case focusedMonitor(MonitorID, name: String, workspace: WorkspaceID)
    case createWorkspace(WorkspaceID)
    case destroyWorkspace(WorkspaceID)
    case moveWindow(WindowID, workspace: WorkspaceID)
    case activeSpecial(String?, monitorName: String)
    case changeFloatingMode(WindowID, floating: Bool)
    case windowTitle(WindowID, title: String)
    case submap(String)
    case configReloaded
    case monitorAdded(String)
    case monitorRemoved(String)

    /// Hyprland's `EVENT>>DATA` form. Window addresses are printed as hex
    /// window ids.
    public var line: String {
        func address(_ id: WindowID?) -> String { id.map { String($0, radix: 16) } ?? "" }
        switch self {
        case let .openWindow(id, workspace, bundleID, title):
            return "openwindow>>\(address(id)),\(workspace),\(bundleID),\(title)"
        case .closeWindow(let id):
            return "closewindow>>\(address(id))"
        case let .activeWindow(id, bundleID, title):
            return id == nil ? "activewindow>>," : "activewindow>>\(bundleID),\(title)"
        case .workspace(let id):
            return "workspace>>\(id)"
        case let .focusedMonitor(_, name, workspace):
            return "focusedmon>>\(name),\(workspace)"
        case .createWorkspace(let id):
            return "createworkspace>>\(id)"
        case .destroyWorkspace(let id):
            return "destroyworkspace>>\(id)"
        case let .moveWindow(id, workspace):
            return "movewindow>>\(address(id)),\(workspace)"
        case let .activeSpecial(name, monitorName):
            return "activespecial>>\(name.map { "special:\($0)" } ?? ""),\(monitorName)"
        case let .changeFloatingMode(id, floating):
            return "changefloatingmode>>\(address(id)),\(floating ? 1 : 0)"
        case let .windowTitle(id, _):
            return "windowtitle>>\(address(id))"
        case .submap(let name):
            return "submap>>\(name)"
        case .configReloaded:
            return "configreloaded>>"
        case .monitorAdded(let name):
            return "monitoradded>>\(name)"
        case .monitorRemoved(let name):
            return "monitorremoved>>\(name)"
        }
    }
}

/// Where the applier should put a window.
public enum Placement: Equatable, Sendable {
    case frame(CGRect)
    /// Parked in the hide corner; the point is the window's origin.
    case hidden(CGPoint)
}

public struct Plan: Equatable, Sendable {
    public var placements: [WindowID: Placement] = [:]

    public init() {}

    public func frame(of id: WindowID) -> CGRect? {
        if case .frame(let rect)? = placements[id] { return rect }
        return nil
    }
}
