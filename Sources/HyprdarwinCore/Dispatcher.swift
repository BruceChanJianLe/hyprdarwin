import CoreGraphics
import Foundation

/// Which windows hl.dsp.window.cycle_next visits.
public enum CycleFilter: String, Sendable {
    case all, floating, tiled
}

public enum ToggleAction: String, Sendable {
    case toggle, set, unset

    public func apply(to current: Bool) -> Bool {
        switch self {
        case .toggle: return !current
        case .set: return true
        case .unset: return false
        }
    }
}

/// Everything a bind (or, later, IPC) can ask the window manager to do.
/// Mirrors the hl.dsp.* constructors of Hyprland's Lua API.
public enum Dispatcher: Equatable, Sendable, CustomStringConvertible {
    case exec(String)
    case closeWindow
    case killWindow
    case float(ToggleAction)
    case fullscreen(FullscreenMode, ToggleAction)
    case moveToWorkspace(WorkspaceSelector, follow: Bool)
    case moveToMonitor(MonitorSelector, follow: Bool)
    case moveDirection(Direction)
    /// Floating windows only: move by/to (x, y).
    case moveBy(x: Double, y: Double, relative: Bool)
    case swapDirection(Direction)
    case resize(x: Double, y: Double, relative: Bool)
    case center
    case focusDirection(Direction)
    case focusWorkspace(WorkspaceSelector, onCurrentMonitor: Bool)
    case focusMonitor(MonitorSelector)
    case focusLast
    /// hl.dsp.window.cycle_next: the next (or previous) window of the workspace.
    case cycleWindows(CycleFilter, reverse: Bool)
    case toggleSpecial(String)
    case moveWorkspaceToMonitor(WorkspaceSelector?, MonitorSelector)
    case layoutMessage(String)
    /// hd.dsp.cycle_layout: the focused workspace takes the next (or
    /// previous) layout of `LayoutKind.defaultCycle`, like tmux's next-layout.
    case cycleLayout(reverse: Bool)
    /// hd.dsp.retile: reapply window rules to every window, rebuild every
    /// workspace's layout with even splits and rewrite every frame.
    case retile
    case submap(String)
    case reload
    case exit
    case noOp

    public var description: String {
        switch self {
        case .exec(let command): return "exec_cmd(\(command))"
        case .closeWindow: return "window.close"
        case .killWindow: return "window.kill"
        case .float(let action): return "window.float(\(action.rawValue))"
        case let .fullscreen(mode, action): return "window.fullscreen(\(mode.rawValue), \(action.rawValue))"
        case let .moveToWorkspace(selector, follow): return "window.move(workspace=\(selector), follow=\(follow))"
        case let .moveToMonitor(selector, follow): return "window.move(monitor=\(selector), follow=\(follow))"
        case .moveDirection(let direction): return "window.move(direction=\(direction.rawValue))"
        case let .moveBy(x, y, relative): return "window.move(x=\(x), y=\(y), relative=\(relative))"
        case .swapDirection(let direction): return "window.swap(direction=\(direction.rawValue))"
        case let .resize(x, y, relative): return "window.resize(x=\(x), y=\(y), relative=\(relative))"
        case .center: return "window.center"
        case .focusDirection(let direction): return "focus(direction=\(direction.rawValue))"
        case let .focusWorkspace(selector, onCurrent): return "focus(workspace=\(selector)\(onCurrent ? ", on_current_monitor" : ""))"
        case .focusMonitor(let selector): return "focus(monitor=\(selector))"
        case .focusLast: return "focus(last)"
        case let .cycleWindows(filter, reverse): return "window.cycle_next(\(filter.rawValue)\(reverse ? ", prev" : ""))"
        case .toggleSpecial(let name): return "workspace.toggle_special(\(name))"
        case let .moveWorkspaceToMonitor(workspace, monitor):
            return "workspace.move(\(workspace.map { "workspace=\($0), " } ?? "")monitor=\(monitor))"
        case .layoutMessage(let message): return "layout(\(message))"
        case .cycleLayout(let reverse): return "hd.cycle_layout(\(reverse ? "prev" : "next"))"
        case .retile: return "hd.retile"
        case .submap(let name): return "submap(\(name))"
        case .reload: return "reload_config"
        case .exit: return "exit"
        case .noOp: return "no_op"
        }
    }
}
