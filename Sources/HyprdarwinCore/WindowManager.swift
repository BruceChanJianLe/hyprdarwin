import CoreGraphics
import Foundation

public struct Workspace: Equatable, Sendable {
    public let id: WorkspaceID
    public var monitorID: MonitorID
    public var layout: WorkspaceLayout
    public var lastFocused: WindowID?

    public init(id: WorkspaceID, monitorID: MonitorID, layout: WorkspaceLayout) {
        self.id = id
        self.monitorID = monitorID
        self.layout = layout
    }
}

public struct MonitorState: Equatable, Sendable {
    /// The numbered workspace shown on the monitor.
    public var activeWorkspace: WorkspaceID
    /// Name of the special workspace shown over it, if any.
    public var special: String?
}

/// The whole window-manager state as a pure model: windows, workspaces,
/// monitors, focus and layouts. The app feeds it what the window source sees
/// and what the user dispatches; it answers with a `Plan` (where every window
/// goes) plus `Effect`s, and queues `WMEvent`s for observers. It never talks
/// to the system, so it is fully unit-testable.
///
/// Not thread-safe: the app owns it on the main thread.
public final class WindowManager {
    public internal(set) var config: Config
    public internal(set) var monitors: [Monitor] = []
    public internal(set) var monitorStates: [MonitorID: MonitorState] = [:]
    public internal(set) var windows: [WindowID: ManagedWindow] = [:]
    public internal(set) var workspaces: [WorkspaceID: Workspace] = [:]
    public internal(set) var focusedWindow: WindowID?
    public internal(set) var focusedMonitorID: MonitorID?
    /// "" is the global bind map.
    public internal(set) var submap = ""
    /// Latest cursor position, used for dwindle placement and warps.
    public var cursor: CGPoint?

    var previousWorkspace: WorkspaceID?
    /// Workspaces that moved off an unplugged monitor, by that monitor's
    /// name, and what it showed; they go back when it returns.
    var displacedWorkspaces: [WorkspaceID: String] = [:]
    var displacedActive: [String: WorkspaceID] = [:]
    /// Most recently focused last.
    var focusHistory: [WindowID] = []
    private var pendingEvents: [WMEvent] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    public func drainEvents() -> [WMEvent] {
        defer { pendingEvents.removeAll() }
        return pendingEvents
    }

    func emit(_ event: WMEvent) { pendingEvents.append(event) }

    // MARK: - Queries

    public var focusedMonitor: Monitor? {
        monitors.first { $0.id == focusedMonitorID } ?? monitors.first
    }

    /// The workspace new windows open on and relative selectors start from.
    public var focusedWorkspaceID: WorkspaceID? {
        guard let monitor = focusedMonitor, let state = monitorStates[monitor.id] else { return nil }
        if let special = state.special { return .special(special) }
        return state.activeWorkspace
    }

    public func monitor(id: MonitorID) -> Monitor? { monitors.first { $0.id == id } }

    public func isVisible(_ id: WorkspaceID) -> Bool {
        guard let workspace = workspaces[id], let state = monitorStates[workspace.monitorID] else {
            // an active workspace that has no windows yet still counts
            return monitorStates.values.contains { $0.activeWorkspace == id }
        }
        switch id {
        case .numbered: return state.activeWorkspace == id
        case .special(let name): return state.special == name
        }
    }

    public func windows(on id: WorkspaceID) -> [ManagedWindow] {
        windows.values.filter { $0.workspace == id }.sorted { $0.id < $1.id }
    }

    public func gapsIn(for id: WorkspaceID) -> Insets { config.workspaceRule(for: id)?.gapsIn ?? config.gapsIn }
    public func gapsOut(for id: WorkspaceID) -> Insets { config.workspaceRule(for: id)?.gapsOut ?? config.gapsOut }

    /// Area the tiled windows of `id` share.
    public func tilingArea(for id: WorkspaceID) -> CGRect? {
        guard let workspace = workspaces[id], let monitor = monitor(id: workspace.monitorID) else { return nil }
        return monitor.visibleFrame.inset(by: gapsOut(for: id))
    }

    // MARK: - Monitors

    /// Replace the monitor set. The first monitor is the primary display.
    public func setMonitors(_ newMonitors: [Monitor]) {
        guard !newMonitors.isEmpty else { return }
        let oldIDs = Set(monitors.map(\.id))
        let newIDs = Set(newMonitors.map(\.id))
        let removed = monitors.filter { !newIDs.contains($0.id) }
        let oldMonitors = monitors
        monitors = newMonitors

        // workspaces of removed monitors move to the primary monitor, hidden
        let fallback = newMonitors[0]
        for gone in removed {
            displacedActive[gone.name] = monitorStates[gone.id]?.activeWorkspace
            for id in workspaces.keys where workspaces[id]?.monitorID == gone.id {
                reassign(workspace: id, to: fallback, from: gone)
                displacedWorkspaces[id] = gone.name
            }
            monitorStates[gone.id] = nil
            emit(.monitorRemoved(gone.name))
        }

        for monitor in newMonitors where !oldIDs.contains(monitor.id) {
            for (id, name) in displacedWorkspaces where name == monitor.name {
                displacedWorkspaces[id] = nil
                if let current = workspaces[id].flatMap({ self.monitor(id: $0.monitorID) }) {
                    reassign(workspace: id, to: monitor, from: current)
                }
            }
            var start = initialWorkspace(for: monitor)
            if let previous = displacedActive.removeValue(forKey: monitor.name),
               workspaces[previous]?.monitorID == monitor.id {
                start = previous
            }
            monitorStates[monitor.id] = MonitorState(activeWorkspace: start, special: nil)
            if workspaces[start] == nil {
                createWorkspace(start, on: monitor.id)
            } else if let current = workspaces[start]?.monitorID, current != monitor.id,
                      let from = oldMonitors.first(where: { $0.id == current }) ?? self.monitor(id: current) {
                reassign(workspace: start, to: monitor, from: from)
            }
            if !oldIDs.isEmpty { emit(.monitorAdded(monitor.name)) }
        }

        // a monitor whose active workspace was moved away needs a new one
        for monitor in newMonitors {
            guard let state = monitorStates[monitor.id] else { continue }
            if workspaces[state.activeWorkspace]?.monitorID != monitor.id {
                let replacement = firstHiddenWorkspace(on: monitor.id) ?? .numbered(nextFreeNumber())
                if workspaces[replacement] == nil { createWorkspace(replacement, on: monitor.id) }
                monitorStates[monitor.id]?.activeWorkspace = replacement
            }
        }

        if focusedMonitorID == nil || !newIDs.contains(focusedMonitorID!) {
            focusedMonitorID = fallback.id
        }
        collectGarbage()
    }

    private func initialWorkspace(for monitor: Monitor) -> WorkspaceID {
        let active = Set(monitorStates.values.map(\.activeWorkspace))
        if let rule = config.workspaceRules.first(where: {
            $0.isDefault && !$0.workspace.isSpecial && matches(monitorName: $0.monitor, monitor)
                && !active.contains($0.workspace)
        }) {
            return rule.workspace
        }
        // else the lowest number not shown elsewhere and not bound to another monitor
        var number = 1
        while true {
            let id = WorkspaceID.numbered(number)
            let ruleMonitor = config.workspaceRule(for: id)?.monitor
            let boundElsewhere = ruleMonitor != nil && !matches(monitorName: ruleMonitor, monitor)
            let taken = active.contains(id) || (workspaces[id].map { $0.monitorID != monitor.id && monitorStates[$0.monitorID] != nil } ?? false)
            if !taken && !boundElsewhere { return id }
            number += 1
        }
    }

    func matches(monitorName: String?, _ monitor: Monitor) -> Bool {
        guard let monitorName else { return false }
        if monitorName == monitor.name { return true }
        if let selector = MonitorSelector(parsing: monitorName), case .index(let index) = selector {
            let sorted = monitors.spatiallySorted
            return index < sorted.count && sorted[index].id == monitor.id
        }
        return monitor.name.localizedCaseInsensitiveContains(monitorName)
    }

    private func firstHiddenWorkspace(on monitorID: MonitorID) -> WorkspaceID? {
        let active = Set(monitorStates.values.map(\.activeWorkspace))
        return workspaces.values
            .filter { $0.monitorID == monitorID && !$0.id.isSpecial && !active.contains($0.id) }
            .map(\.id).sorted().first
    }

    func nextFreeNumber() -> Int {
        var number = 1
        while workspaces[.numbered(number)] != nil || monitorStates.values.contains(where: { $0.activeWorkspace == .numbered(number) }) {
            number += 1
        }
        return number
    }

    /// Move a workspace to another monitor, carrying floating windows along.
    func reassign(workspace id: WorkspaceID, to target: Monitor, from source: Monitor) {
        guard var workspace = workspaces[id], workspace.monitorID != target.id else { return }
        workspace.monitorID = target.id
        workspaces[id] = workspace
        for window in windows.values where window.workspace == id {
            windows[window.id]?.floatingFrame = translate(window.floatingFrame, from: source, to: target)
        }
    }

    func translate(_ frame: CGRect, from source: Monitor, to target: Monitor) -> CGRect {
        guard source.id != target.id else { return frame }
        let dx = frame.minX - source.visibleFrame.minX
        let dy = frame.minY - source.visibleFrame.minY
        var moved = CGRect(x: target.visibleFrame.minX + dx, y: target.visibleFrame.minY + dy, width: frame.width, height: frame.height)
        moved = clamp(moved, to: target.visibleFrame)
        return moved
    }

    func clamp(_ frame: CGRect, to area: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(frame.width, area.width)
        result.size.height = min(frame.height, area.height)
        result.origin.x = min(max(frame.minX, area.minX), area.maxX - result.width)
        result.origin.y = min(max(frame.minY, area.minY), area.maxY - result.height)
        return result
    }

    // MARK: - Workspaces

    @discardableResult
    func createWorkspace(_ id: WorkspaceID, on monitorID: MonitorID) -> Workspace {
        if let existing = workspaces[id] { return existing }
        let kind = config.workspaceRule(for: id)?.layout ?? config.layout
        let workspace = Workspace(id: id, monitorID: monitorID, layout: WorkspaceLayout(kind: kind, options: config.layoutOptions))
        workspaces[id] = workspace
        emit(.createWorkspace(id))
        return workspace
    }

    /// The workspace, created on its rule's monitor (or the focused one) if needed.
    func ensureWorkspace(_ id: WorkspaceID) -> Workspace {
        if let existing = workspaces[id] { return existing }
        let ruleMonitor = config.workspaceRule(for: id)?.monitor
        let monitor = monitors.first { matches(monitorName: ruleMonitor, $0) } ?? focusedMonitor
        return createWorkspace(id, on: monitor?.id ?? 0)
    }

    /// Drop empty workspaces that are not shown and not persistent.
    func collectGarbage() {
        for (id, _) in workspaces {
            guard !isVisible(id), config.workspaceRule(for: id)?.persistent != true else { continue }
            guard !windows.values.contains(where: { $0.workspace == id }) else { continue }
            workspaces[id] = nil
            emit(.destroyWorkspace(id))
        }
    }

    // MARK: - Config

    public func setConfig(_ newConfig: Config) {
        let old = config
        config = newConfig
        for (id, workspace) in workspaces {
            let kind = newConfig.workspaceRule(for: id)?.layout ?? newConfig.layout
            var layout = workspace.layout
            if layout.kind != kind, let area = tilingArea(for: id) {
                layout = layout.converted(to: kind, area: area, options: newConfig.layoutOptions)
            }
            if case .master(var master) = layout {
                if old.layoutOptions.master.mfact != newConfig.layoutOptions.master.mfact {
                    master.mfact = newConfig.layoutOptions.master.mfact
                }
                if old.layoutOptions.master.orientation != newConfig.layoutOptions.master.orientation {
                    master.orientation = newConfig.layoutOptions.master.orientation
                }
                layout = .master(master)
            }
            workspaces[id]?.layout = layout
        }
        for id in windows.keys { applyDynamicRules(to: id) }
        if !submap.isEmpty && !newConfig.submaps.contains(submap) {
            submap = ""
            emit(.submap(""))
        }
        emit(.configReloaded)
    }

    // MARK: - Windows

    /// A window the source reported. `isNew` is true for windows that just
    /// opened (rules may focus or move them); false for windows that were
    /// already open when hyprdarwin started or regained management.
    @discardableResult
    public func addWindow(_ info: WindowInfo, isNew: Bool) -> [Effect] {
        if windows[info.id] != nil {
            updateInfo(info)
            return []
        }
        guard let fallbackMonitor = focusedMonitor else { return [] }
        let monitor = isNew ? fallbackMonitor : (monitors.best(for: info.frame) ?? fallbackMonitor)
        guard let state = monitorStates[monitor.id] else { return [] }
        let defaultWorkspace: WorkspaceID
        if let special = state.special, isNew, monitor.id == focusedMonitorID {
            defaultWorkspace = .special(special)
        } else {
            defaultWorkspace = state.activeWorkspace
        }

        var window = ManagedWindow(info: info, workspace: defaultWorkspace, isFloating: !info.isResizable)
        let effects = RuleEngine.effects(for: window, rules: config.windowRules)
        if let float = effects.float { window.isFloating = float }
        window.fullscreen = effects.fullscreen
        window.tags.formUnion(effects.tags)
        window.borderColor = effects.borderColor
        window.borderSize = effects.borderSize

        var silent = !isNew
        if let target = effects.workspace {
            window.workspace = target.workspace
            silent = silent || target.silent
        } else if let selector = effects.monitor, let target = resolve(monitor: selector), let targetState = monitorStates[target.id] {
            window.workspace = targetState.activeWorkspace
        }

        let workspace = ensureWorkspace(window.workspace)
        let targetMonitor = self.monitor(id: workspace.monitorID) ?? monitor
        if let source = monitors.best(for: info.frame), source.id != targetMonitor.id {
            window.floatingFrame = translate(info.frame, from: source, to: targetMonitor)
        }
        window.floatingFrame = initialFloatingFrame(for: window, effects: effects, on: targetMonitor)

        windows[info.id] = window
        if !window.isFloating, let area = tilingArea(for: window.workspace) {
            let near = workspace.lastFocused ?? (focusedWindow.flatMap { windows[$0]?.workspace == window.workspace ? $0 : nil })
            workspaces[window.workspace]?.layout.insert(info.id, focused: near, area: area, options: config.layoutOptions, cursor: cursor)
        }
        if workspaces[window.workspace]?.lastFocused == nil {
            workspaces[window.workspace]?.lastFocused = info.id
        }
        emit(.openWindow(info.id, workspace: window.workspace, bundleID: info.bundleID, title: info.title))

        guard isNew, effects.noInitialFocus != true else { return [] }
        if silent && !isVisible(window.workspace) {
            workspaces[window.workspace]?.lastFocused = info.id
            return []
        }
        var result: [Effect] = []
        if !isVisible(window.workspace) {
            result += show(workspace: window.workspace)
        }
        result += focus(info.id, warp: false)
        return result
    }

    /// The source no longer sees the window (closed, minimized, app quit).
    @discardableResult
    public func removeWindow(_ id: WindowID) -> [Effect] {
        guard let window = windows.removeValue(forKey: id) else { return [] }
        workspaces[window.workspace]?.layout.remove(id)
        focusHistory.removeAll { $0 == id }
        if workspaces[window.workspace]?.lastFocused == id {
            workspaces[window.workspace]?.lastFocused = mostRecent(on: window.workspace)
        }
        emit(.closeWindow(id))
        var effects: [Effect] = []
        if focusedWindow == id {
            focusedWindow = nil
            effects = focusFallback(preferring: window.workspace)
        }
        collectGarbage()
        return effects
    }

    /// Title or other metadata changed.
    public func updateInfo(_ info: WindowInfo) {
        guard var window = windows[info.id] else { return }
        let titleChanged = window.info.title != info.title
        window.info.title = info.title
        window.info.appName = info.appName
        window.info.isResizable = info.isResizable
        window.info.role = info.role
        window.info.subrole = info.subrole
        windows[info.id] = window
        if titleChanged {
            emit(.windowTitle(info.id, title: info.title))
            applyDynamicRules(to: info.id)
        }
    }

    /// The window's real frame as last read; floating windows keep it as
    /// their home (the user moved or resized them).
    public func windowFrameChanged(_ id: WindowID, frame: CGRect) {
        guard var window = windows[id] else { return }
        window.info.frame = frame
        if window.isFloating, window.fullscreen == nil, isVisible(window.workspace) {
            window.floatingFrame = frame
        }
        windows[id] = window
    }

    /// The OS moved keyboard focus (click, Cmd-Tab, app activation). A window
    /// on a hidden workspace brings its workspace into view.
    @discardableResult
    public func externalFocus(_ id: WindowID) -> [Effect] {
        guard let window = windows[id] else { return [] }
        var effects: [Effect] = []
        if !isVisible(window.workspace) {
            effects += show(workspace: window.workspace)
        }
        markFocused(id)
        return effects
    }

    func applyDynamicRules(to id: WindowID) {
        guard var window = windows[id] else { return }
        let effects = RuleEngine.dynamicEffects(for: window, rules: config.windowRules)
        window.borderColor = effects.borderColor
        window.borderSize = effects.borderSize
        windows[id] = window
        if let float = effects.float, float != window.isFloating {
            setFloating(id, float)
        }
    }

    func initialFloatingFrame(for window: ManagedWindow, effects: WindowRuleEffects, on monitor: Monitor) -> CGRect {
        let area = monitor.visibleFrame
        var frame = window.floatingFrame
        func variables(_ size: CGSize) -> RuleExpression.Variables {
            RuleExpression.Variables(
                monitorW: area.width, monitorH: area.height, windowW: size.width, windowH: size.height,
                cursorX: (cursor?.x ?? area.midX) - area.minX, cursorY: (cursor?.y ?? area.midY) - area.minY
            )
        }
        if let size = effects.size, let (wText, hText) = RuleExpression.splitPair(size),
           case .success(let w) = RuleExpression.evaluate(wText, horizontal: true, variables: variables(frame.size)),
           case .success(let h) = RuleExpression.evaluate(hText, horizontal: false, variables: variables(frame.size)) {
            frame.size = CGSize(width: max(1, w), height: max(1, h))
        }
        if effects.center == true {
            frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        }
        if let move = effects.move, let (xText, yText) = RuleExpression.splitPair(move),
           case .success(let x) = RuleExpression.evaluate(xText, horizontal: true, variables: variables(frame.size)),
           case .success(let y) = RuleExpression.evaluate(yText, horizontal: false, variables: variables(frame.size)) {
            frame.origin = CGPoint(x: area.minX + x, y: area.minY + y)
        }
        if !area.intersects(frame) {
            frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        }
        return frame.integral
    }

    // MARK: - Focus

    func markFocused(_ id: WindowID) {
        guard let window = windows[id] else { return }
        let changed = focusedWindow != id
        focusedWindow = id
        workspaces[window.workspace]?.lastFocused = id
        focusHistory.removeAll { $0 == id }
        focusHistory.append(id)
        if let workspace = workspaces[window.workspace], workspace.monitorID != focusedMonitorID {
            setFocusedMonitor(workspace.monitorID)
        }
        if changed {
            emit(.activeWindow(id, bundleID: window.info.bundleID, title: window.info.title))
        }
    }

    func setFocusedMonitor(_ id: MonitorID) {
        guard focusedMonitorID != id, let monitor = monitor(id: id), let state = monitorStates[id] else { return }
        focusedMonitorID = id
        emit(.focusedMonitor(id, name: monitor.name, workspace: state.special.map { .special($0) } ?? state.activeWorkspace))
    }

    /// Focus a window from inside hyprdarwin (keyboard, rules).
    func focus(_ id: WindowID, warp: Bool) -> [Effect] {
        guard windows[id] != nil else { return [] }
        markFocused(id)
        var effects: [Effect] = [.focus(id)]
        if warp, config.followMouse == 1, !config.noWarps, let frame = computePlan().frame(of: id) {
            if cursor.map({ !frame.contains($0) }) ?? true {
                effects.append(.warpCursor(frame.center))
                cursor = frame.center
            }
        }
        return effects
    }

    func mostRecent(on workspace: WorkspaceID) -> WindowID? {
        focusHistory.last { windows[$0]?.workspace == workspace }
            ?? windows.values.filter { $0.workspace == workspace }.map(\.id).min()
    }

    /// Focus something sensible after the focused window went away.
    func focusFallback(preferring workspace: WorkspaceID?, warp: Bool = false) -> [Effect] {
        var candidates: [WorkspaceID] = []
        if let workspace, isVisible(workspace) { candidates.append(workspace) }
        if let focused = focusedWorkspaceID { candidates.append(focused) }
        if let monitor = focusedMonitorID, let state = monitorStates[monitor] {
            candidates.append(state.activeWorkspace)
        }
        for candidate in candidates {
            if let id = workspaces[candidate]?.lastFocused.flatMap({ windows[$0]?.workspace == candidate ? $0 : nil })
                ?? mostRecent(on: candidate) {
                return focus(id, warp: warp)
            }
        }
        if focusedWindow != nil {
            focusedWindow = nil
            emit(.activeWindow(nil, bundleID: "", title: ""))
        }
        return []
    }

    // MARK: - Showing workspaces

    /// Bring `id` into view on its monitor (special workspaces open over it).
    func show(workspace id: WorkspaceID) -> [Effect] {
        let workspace = ensureWorkspace(id)
        guard let monitor = monitor(id: workspace.monitorID) else { return [] }
        switch id {
        case .numbered:
            let current = monitorStates[monitor.id]?.activeWorkspace
            if current != id {
                if let focused = focusedWorkspaceID, !focused.isSpecial { previousWorkspace = focused }
                monitorStates[monitor.id]?.activeWorkspace = id
                if monitorStates[monitor.id]?.special != nil {
                    monitorStates[monitor.id]?.special = nil
                    emit(.activeSpecial(nil, monitorName: monitor.name))
                }
                emit(.workspace(id))
            }
        case .special(let name):
            // one special workspace can only be open on one monitor
            for (other, state) in monitorStates where state.special == name && other != monitor.id {
                monitorStates[other]?.special = nil
            }
            if monitorStates[monitor.id]?.special != name {
                monitorStates[monitor.id]?.special = name
                emit(.activeSpecial(name, monitorName: monitor.name))
            }
        }
        setFocusedMonitor(monitor.id)
        collectGarbage()
        return []
    }

    // MARK: - Plan

    /// Where every window should be right now.
    public func computePlan() -> Plan {
        var plan = Plan()
        var tiled: [WindowID: CGRect] = [:]
        for (id, workspace) in workspaces where isVisible(id) {
            guard let area = tilingArea(for: id) else { continue }
            let raw = workspace.layout.frames(in: area, options: config.layoutOptions)
            tiled.merge(Gaps.apply(raw, area: area, gapsIn: gapsIn(for: id))) { a, _ in a }
        }
        for window in windows.values {
            guard isVisible(window.workspace),
                  let workspace = workspaces[window.workspace],
                  let monitor = monitor(id: workspace.monitorID) else {
                plan.placements[window.id] = .hidden(parkingOrigin(for: window))
                continue
            }
            if let mode = window.fullscreen {
                let frame = mode == .fullscreen ? monitor.visibleFrame : monitor.visibleFrame.inset(by: gapsOut(for: window.workspace))
                plan.placements[window.id] = .frame(frame.integral)
            } else if window.isFloating {
                plan.placements[window.id] = .frame(window.floatingFrame.integral)
            } else if let frame = tiled[window.id] {
                plan.placements[window.id] = .frame(frame)
            } else {
                plan.placements[window.id] = .frame(window.floatingFrame.integral)
            }
        }
        return plan
    }

    /// Hidden windows wait just outside the bottom corner of the outermost
    /// monitor with a 1 pt sliver left on screen. Parking beyond the
    /// right-most (or left-most) monitor keeps the window clear of every
    /// other display, which avoids WindowServer rescaling a window that
    /// straddles two monitors.
    /// Technique adapted from HyprMac (MIT, Copyright (c) 2026 Zachary Gray),
    /// WorkspaceManager.hidePosition().
    public func parkingOrigin(for window: ManagedWindow) -> CGPoint {
        switch config.hideCorner {
        case .bottomRight:
            guard let edge = monitors.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return .zero }
            return CGPoint(x: edge.frame.maxX - 1, y: edge.frame.maxY - 1)
        case .bottomLeft:
            guard let edge = monitors.min(by: { $0.frame.minX < $1.frame.minX }) else { return .zero }
            return CGPoint(x: edge.frame.minX - window.info.frame.width + 1, y: edge.frame.maxY - 1)
        }
    }
}
