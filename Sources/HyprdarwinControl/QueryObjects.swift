import CoreGraphics
import Foundation
import HyprdarwinConfig
import HyprdarwinCore

// The objects hyprdarwinctl queries return, shaped like hyprctl's JSON
// (same key names where the meaning matches) plus a few macOS extras.

public struct WorkspaceRef: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
}

public struct ClientObject: Codable, Equatable, Sendable {
    /// "0x" + the hex window id.
    public var address: String
    public var mapped: Bool
    /// On a workspace that is not shown (parked in the hide corner).
    public var hidden: Bool
    public var at: [Int]
    public var size: [Int]
    public var workspace: WorkspaceRef
    public var floating: Bool
    /// Index of the workspace's monitor, from the left.
    public var monitor: Int
    /// The bundle id.
    public var `class`: String
    public var title: String
    public var initialClass: String
    public var initialTitle: String
    public var appName: String
    public var pid: Int
    /// 0 none, 1 maximized, 2 fullscreen (Hyprland's numbering).
    public var fullscreen: Int
    /// 0 for the focused window, 1 for the one before... -1 never focused.
    public var focusHistoryID: Int
    public var tags: [String]
    public var role: String
    public var subrole: String
    /// The smallest tile size the window gets (app, learned, min_size rule).
    public var minSize: [Int]
}

public struct WorkspaceObject: Codable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var monitor: String
    public var monitorID: Int
    public var windows: Int
    public var hasfullscreen: Bool
    public var lastwindow: String
    public var lastwindowtitle: String
    public var ispersistent: Bool
    public var tiledLayout: String
    public var visible: Bool
}

public struct MonitorObject: Codable, Equatable, Sendable {
    /// Position from the left, as monitor selectors count.
    public var id: Int
    public var name: String
    public var description: String
    /// CGDirectDisplayID.
    public var displayID: UInt32
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// Points macOS keeps for the menu bar and the Dock: top, right, bottom, left.
    public var reserved: [Int]
    public var activeWorkspace: WorkspaceRef
    public var specialWorkspace: WorkspaceRef
    public var focused: Bool
}

public struct BindObject: Codable, Equatable, Sendable {
    public var modifiers: [String]
    public var key: String
    public var keycode: Int
    /// "" for the global map.
    public var submap: String
    public var repeating: Bool
    public var release: Bool
    public var enabled: Bool
    public var hasDescription: Bool
    public var description: String
    /// What the bind runs: the dispatcher, or "lua function".
    public var dispatcher: String

    enum CodingKeys: String, CodingKey {
        case modifiers, key, keycode, submap, release, enabled, description, dispatcher
        case repeating = "repeat"
        case hasDescription = "has_description"
    }
}

public struct WorkspaceRuleObject: Codable, Equatable, Sendable {
    public var workspaceString: String
    public var monitor: String?
    public var `default`: Bool?
    public var persistent: Bool?
    public var layout: String?
    /// top, right, bottom, left.
    public var gapsIn: [Double]?
    public var gapsOut: [Double]?
}

public struct ConfigMessageObject: Codable, Equatable, Sendable {
    /// "error", "warning" or "info".
    public var severity: String
    public var text: String
}

public struct VersionObject: Codable, Equatable, Sendable {
    public var version: String
    public var commit: String
    public var build: String
    public var origin: String
    /// The whole version line, as the menu shows it.
    public var description: String
}

// MARK: - Building them from the model

extension ClientObject {
    init(_ window: ManagedWindow, model: WindowManager) {
        let frame = window.info.frame
        let workspace = window.workspace
        let monitorID = model.workspaces[workspace]?.monitorID
        let minimum = window.minimumSize
        address = Self.address(window.id)
        mapped = true
        hidden = !model.isVisible(workspace)
        at = [Int(frame.minX.rounded()), Int(frame.minY.rounded())]
        size = [Int(frame.width.rounded()), Int(frame.height.rounded())]
        self.workspace = WorkspaceRef(id: model.numericID(of: workspace), name: workspace.description)
        floating = window.isFloating
        monitor = monitorID.flatMap(model.monitorIndex(of:)) ?? -1
        `class` = window.info.bundleID
        title = window.info.title
        initialClass = window.initialClass
        initialTitle = window.initialTitle
        appName = window.info.appName
        pid = Int(window.info.pid)
        switch window.fullscreen {
        case nil: fullscreen = 0
        case .maximized?: fullscreen = 1
        case .fullscreen?: fullscreen = 2
        }
        focusHistoryID = model.focusHistoryID(of: window.id) ?? -1
        tags = window.tags.sorted()
        role = window.info.role
        subrole = window.info.subrole
        minSize = [Int(minimum.width.rounded()), Int(minimum.height.rounded())]
    }

    static func address(_ id: WindowID) -> String { "0x" + String(id, radix: 16) }
}

extension WorkspaceObject {
    init(_ workspace: Workspace, model: WindowManager) {
        let windows = model.windows(on: workspace.id)
        let monitor = model.monitor(id: workspace.monitorID)
        let last = workspace.lastFocused.flatMap { id in windows.first { $0.id == id } }
        id = model.numericID(of: workspace.id)
        name = workspace.id.description
        self.monitor = monitor?.name ?? ""
        monitorID = model.monitorIndex(of: workspace.monitorID) ?? -1
        self.windows = windows.count
        hasfullscreen = windows.contains { $0.fullscreen != nil }
        lastwindow = last.map { ClientObject.address($0.id) } ?? "0x0"
        lastwindowtitle = last?.info.title ?? ""
        ispersistent = model.config.workspaceRule(for: workspace.id)?.persistent ?? false
        tiledLayout = workspace.layout.kind.rawValue
        visible = model.isVisible(workspace.id)
    }
}

extension MonitorObject {
    init(_ monitor: Monitor, model: WindowManager) {
        let state = model.monitorStates[monitor.id]
        let active = state?.activeWorkspace ?? .numbered(1)
        let frame = monitor.frame
        let visible = monitor.visibleFrame
        id = model.monitorIndex(of: monitor.id) ?? -1
        name = monitor.name
        description = monitor.name
        displayID = monitor.id
        x = Int(frame.minX.rounded())
        y = Int(frame.minY.rounded())
        width = Int(frame.width.rounded())
        height = Int(frame.height.rounded())
        reserved = [visible.minY - frame.minY, frame.maxX - visible.maxX, frame.maxY - visible.maxY, visible.minX - frame.minX]
            .map { Int($0.rounded()) }
        activeWorkspace = WorkspaceRef(id: model.numericID(of: active), name: active.description)
        let special = state?.special.map { WorkspaceID.special($0) }
        specialWorkspace = WorkspaceRef(id: special.map(model.numericID(of:)) ?? 0, name: special?.description ?? "")
        focused = monitor.id == model.focusedMonitorID
    }
}

extension BindObject {
    init(_ bind: Keybind) {
        modifiers = bind.combo.modifiers.description.isEmpty ? [] : bind.combo.modifiers.description.components(separatedBy: " + ")
        key = bind.combo.keyName
        keycode = Int(bind.combo.keyCode)
        submap = bind.submap ?? ""
        repeating = bind.repeating
        release = bind.release
        enabled = bind.enabled
        hasDescription = bind.description?.isEmpty == false
        description = bind.description ?? ""
        dispatcher = ConfigReport.action(bind.action)
    }
}

extension WorkspaceRuleObject {
    init(_ rule: WorkspaceRule) {
        func sides(_ insets: Insets?) -> [Double]? { insets.map { [$0.top, $0.right, $0.bottom, $0.left] } }
        workspaceString = rule.workspace.description
        monitor = rule.monitor
        `default` = rule.isDefault ? true : nil
        persistent = rule.persistent ? true : nil
        layout = rule.layout?.rawValue
        gapsIn = sides(rule.gapsIn)
        gapsOut = sides(rule.gapsOut)
    }
}
