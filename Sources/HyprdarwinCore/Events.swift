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
    /// Forget what was written and rewrite every window (re-tile).
    case rewriteAll
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

/// State changes, named after Hyprland's event socket events; the event
/// socket streams them as `EVENT>>DATA` lines (`lines(id:)`).
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
    /// `index` is the monitor's position from the left, as in the queries.
    case monitorAdded(index: Int, name: String)
    case monitorRemoved(index: Int, name: String)

    /// Hyprland's `EVENT>>DATA` lines: the original event, then its `v2`
    /// form where Hyprland has one. Window addresses are hex window ids
    /// (no 0x, as in Hyprland's events); `id` numbers workspaces (special
    /// ones are negative, see `WindowManager.numericID(of:)`). Monitors have
    /// no separate description on macOS, so v2 repeats the name.
    public func lines(id: (WorkspaceID) -> Int) -> [String] {
        func address(_ id: WindowID?) -> String { id.map { String($0, radix: 16) } ?? "" }
        // one event per line: a newline in a title must not start another
        func text(_ value: String) -> String {
            value.components(separatedBy: .newlines).joined(separator: " ")
        }
        switch self {
        case let .openWindow(window, workspace, bundleID, title):
            return ["openwindow>>\(address(window)),\(workspace),\(text(bundleID)),\(text(title))"]
        case .closeWindow(let window):
            return ["closewindow>>\(address(window))"]
        case let .activeWindow(window, bundleID, title):
            return [window == nil ? "activewindow>>," : "activewindow>>\(text(bundleID)),\(text(title))",
                    "activewindowv2>>\(address(window))"]
        case .workspace(let workspace):
            return ["workspace>>\(workspace)", "workspacev2>>\(id(workspace)),\(workspace)"]
        case let .focusedMonitor(_, name, workspace):
            return ["focusedmon>>\(text(name)),\(workspace)", "focusedmonv2>>\(text(name)),\(id(workspace))"]
        case .createWorkspace(let workspace):
            return ["createworkspace>>\(workspace)", "createworkspacev2>>\(id(workspace)),\(workspace)"]
        case .destroyWorkspace(let workspace):
            return ["destroyworkspace>>\(workspace)", "destroyworkspacev2>>\(id(workspace)),\(workspace)"]
        case let .moveWindow(window, workspace):
            return ["movewindow>>\(address(window)),\(workspace)",
                    "movewindowv2>>\(address(window)),\(id(workspace)),\(workspace)"]
        case let .activeSpecial(name, monitorName):
            let workspace = name.map { WorkspaceID.special($0) }
            return ["activespecial>>\(workspace?.description ?? ""),\(text(monitorName))",
                    "activespecialv2>>\(workspace.map { String(id($0)) } ?? ""),\(workspace?.description ?? ""),\(text(monitorName))"]
        case let .changeFloatingMode(window, floating):
            return ["changefloatingmode>>\(address(window)),\(floating ? 1 : 0)"]
        case let .windowTitle(window, title):
            return ["windowtitle>>\(address(window))", "windowtitlev2>>\(address(window)),\(text(title))"]
        case .submap(let name):
            return ["submap>>\(name)"]
        case .configReloaded:
            return ["configreloaded>>"]
        case let .monitorAdded(index, name):
            return ["monitoradded>>\(text(name))", "monitoraddedv2>>\(index),\(text(name)),\(text(name))"]
        case let .monitorRemoved(index, name):
            return ["monitorremoved>>\(text(name))", "monitorremovedv2>>\(index),\(text(name)),\(text(name))"]
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
    /// Tiled windows whose minimum size does not fit their workspace: they
    /// float on top, centred, until there is room for them again.
    public var overflow: Set<WindowID> = []

    public init() {}

    public func frame(of id: WindowID) -> CGRect? {
        if case .frame(let rect)? = placements[id] { return rect }
        return nil
    }
}
