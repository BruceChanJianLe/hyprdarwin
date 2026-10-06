import CoreGraphics
import Foundation

extension WindowManager {
    /// Run a dispatcher against the current state.
    @discardableResult
    public func dispatch(_ dispatcher: Dispatcher) -> [Effect] {
        switch dispatcher {
        case .exec(let command):
            return [.exec(command)]
        case .closeWindow:
            return focusedWindow.map { [.close($0)] } ?? []
        case .killWindow:
            guard let id = focusedWindow, let window = windows[id] else { return [] }
            return [.kill(pid: window.info.pid)]
        case .float(let action):
            guard let id = focusedWindow, let window = windows[id] else { return [] }
            setFloating(id, action.apply(to: window.isFloating))
            return []
        case let .fullscreen(mode, action):
            guard let id = focusedWindow, let window = windows[id] else { return [] }
            let on = action.apply(to: window.fullscreen == mode)
            // one fullscreen window per workspace
            if on { exitFullscreen(on: window.workspace) }
            windows[id]?.fullscreen = on ? mode : nil
            return [.focus(id)]
        case let .moveToWorkspace(selector, follow):
            guard let id = focusedWindow, let target = resolve(workspace: selector) else { return [] }
            return move(id, to: target, follow: follow)
        case let .moveToMonitor(selector, follow):
            guard let id = focusedWindow, let monitor = resolve(monitor: selector),
                  let state = monitorStates[monitor.id] else { return [] }
            return move(id, to: state.special.map { .special($0) } ?? state.activeWorkspace, follow: follow)
        case .moveDirection(let direction):
            return moveInDirection(direction)
        case let .moveBy(x, y, relative):
            guard let id = focusedWindow, let window = windows[id], window.isFloating else {
                return [.failed("window.move with x/y only applies to floating windows")]
            }
            var frame = window.floatingFrame
            if relative {
                frame.origin.x += x
                frame.origin.y += y
            } else if let area = monitorArea(of: window) {
                frame.origin = CGPoint(x: area.minX + x, y: area.minY + y)
            }
            windows[id]?.floatingFrame = frame
            return []
        case .swapDirection(let direction):
            return swapInDirection(direction)
        case let .resize(x, y, relative):
            return resizeFocused(x: x, y: y, relative: relative)
        case .center:
            guard let id = focusedWindow, let window = windows[id], window.isFloating,
                  let area = monitorArea(of: window) else { return [] }
            var frame = window.floatingFrame
            frame.origin = CGPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            windows[id]?.floatingFrame = frame.integral
            return []
        case .focusDirection(let direction):
            return focusInDirection(direction)
        case let .focusWorkspace(selector, onCurrentMonitor):
            guard let target = resolve(workspace: selector) else { return [] }
            if case .special(let name) = target { return toggleSpecial(name, show: true) }
            return switchTo(workspace: target, onCurrentMonitor: onCurrentMonitor)
        case .focusMonitor(let selector):
            guard let monitor = resolve(monitor: selector) else { return [] }
            return focusMonitor(monitor)
        case .focusLast:
            guard let previous = focusHistory.dropLast().last(where: { windows[$0] != nil }) else { return [] }
            var effects = externalFocus(previous)
            effects += focus(previous, warp: true)
            return effects
        case .toggleSpecial(let name):
            return toggleSpecial(name.isEmpty ? WorkspaceID.defaultSpecialName : name, show: nil)
        case let .moveWorkspaceToMonitor(selector, monitorSelector):
            guard let monitor = resolve(monitor: monitorSelector) else { return [] }
            let id = selector.flatMap(resolve(workspace:)) ?? focusedWorkspaceID
            guard let id else { return [] }
            return moveWorkspace(id, to: monitor)
        case .layoutMessage(let message):
            return layoutMessage(message)
        case .cycleLayout(let reverse):
            let cycle = LayoutKind.defaultCycle
            guard let id = focusedWorkspaceID, let workspace = workspaces[id], let area = tilingArea(for: id),
                  let index = cycle.firstIndex(of: workspace.layout.kind) else { return [] }
            let next = cycle[(index + (reverse ? cycle.count - 1 : 1)) % cycle.count]
            layoutOverrides[id] = next
            workspaces[id]?.layout = workspace.layout.converted(to: next, area: area, options: config.layoutOptions)
            return []
        case .retile:
            return retile()
        case let .cycleWindows(filter, reverse):
            return cycleWindows(filter, reverse: reverse)
        case .submap(let name):
            let target = (name == "reset" || name.isEmpty) ? "" : name
            guard target.isEmpty || config.submaps.contains(target) else {
                return [.failed("submap \"\(name)\" is not defined")]
            }
            guard target != submap else { return [] }
            submap = target
            emit(.submap(target))
            return [.submap(target)]
        case .reload:
            return [.reload]
        case .exit:
            return [.exit]
        case .noOp:
            return []
        }
    }

    // MARK: - Selectors

    public func resolve(workspace selector: WorkspaceSelector) -> WorkspaceID? {
        let currentNumber: Int = {
            if let monitor = focusedMonitorID, let state = monitorStates[monitor] { return state.activeWorkspace.number ?? 1 }
            return 1
        }()
        switch selector {
        case .id(let id):
            return id
        case .relative(let delta):
            return .numbered(max(1, currentNumber + delta))
        case .relativeOnMonitor(let delta):
            let monitorID = focusedMonitor?.id
            let elsewhere = Set(workspaces.values.filter { $0.monitorID != monitorID }.compactMap(\.id.number))
            let step = delta >= 0 ? 1 : -1
            var number = currentNumber
            for _ in 0..<abs(delta) {
                var next = number + step
                while next >= 1 && elsewhere.contains(next) { next += step }
                guard next >= 1 else { break }
                number = next
            }
            return .numbered(number)
        case .existing(let delta), .existingOnMonitor(let delta):
            var existing = Set(workspaces.keys.compactMap(\.number))
            if case .existingOnMonitor = selector {
                existing = Set(workspaces.values.filter { $0.monitorID == focusedMonitorID }.compactMap(\.id.number))
            }
            existing.insert(currentNumber)
            let sorted = existing.sorted()
            guard let index = sorted.firstIndex(of: currentNumber), !sorted.isEmpty else { return nil }
            let next = ((index + delta) % sorted.count + sorted.count) % sorted.count
            return .numbered(sorted[next])
        case .previous:
            return previousWorkspace ?? .numbered(currentNumber)
        case .empty:
            var number = 1
            while windows.values.contains(where: { $0.workspace == .numbered(number) }) { number += 1 }
            return .numbered(number)
        }
    }

    public func resolve(monitor selector: MonitorSelector) -> Monitor? {
        let sorted = monitors.spatiallySorted
        let current = focusedMonitor
        switch selector {
        case .current:
            return current
        case .index(let index):
            return index < sorted.count ? sorted[index] : nil
        case .name(let name):
            return monitors.first { $0.name == name } ?? monitors.first { $0.name.localizedCaseInsensitiveContains(name) }
        case .relative(let delta):
            guard let current, let index = sorted.firstIndex(where: { $0.id == current.id }) else { return nil }
            return sorted[((index + delta) % sorted.count + sorted.count) % sorted.count]
        case .direction(let direction):
            guard let current else { return nil }
            let others = monitors.filter { $0.id != current.id }.map { (id: $0.id, frame: $0.frame) }
            let id = Neighbor.find(from: current.frame, direction: direction, among: others)
            return id.flatMap { monitor(id: $0) }
        }
    }

    // MARK: - Implementations

    func monitorArea(of window: ManagedWindow) -> CGRect? {
        workspaces[window.workspace].flatMap { monitor(id: $0.monitorID) }?.visibleFrame
    }

    func setFloating(_ id: WindowID, _ floating: Bool) {
        guard let window = windows[id], window.isFloating != floating else { return }
        windows[id]?.isFloating = floating
        if floating {
            workspaces[window.workspace]?.layout.remove(id)
            // floats back where it last floated (or opened); centred if that is off-monitor
            if let area = monitorArea(of: window), !area.intersects(window.floatingFrame) {
                let width = min(window.floatingFrame.width, area.width)
                let height = min(window.floatingFrame.height, area.height)
                windows[id]?.floatingFrame = CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height).integral
            }
        } else if let area = tilingArea(for: window.workspace) {
            let near = workspaces[window.workspace]?.lastFocused.flatMap { $0 == id ? nil : $0 }
            workspaces[window.workspace]?.layout.insert(id, focused: near, area: area, options: config.layoutOptions, cursor: cursor)
        }
        emit(.changeFloatingMode(id, floating: floating))
    }

    func move(_ id: WindowID, to target: WorkspaceID, follow: Bool) -> [Effect] {
        guard let window = windows[id], window.workspace != target else { return [] }
        let source = window.workspace
        let targetWorkspace = ensureWorkspace(target)
        workspaces[source]?.layout.remove(id)
        if workspaces[source]?.lastFocused == id {
            workspaces[source]?.lastFocused = focusHistory.last { $0 != id && windows[$0]?.workspace == source }
        }
        if let from = workspaces[source].flatMap({ monitor(id: $0.monitorID) }),
           let to = monitor(id: targetWorkspace.monitorID) {
            windows[id]?.floatingFrame = translate(window.floatingFrame, from: from, to: to)
        }
        windows[id]?.workspace = target
        if !window.isFloating, let area = tilingArea(for: target) {
            workspaces[target]?.layout.insert(id, focused: targetWorkspace.lastFocused, area: area, options: config.layoutOptions, cursor: nil)
        }
        workspaces[target]?.lastFocused = id
        emit(.moveWindow(id, workspace: target))

        var effects: [Effect] = []
        if follow {
            if !isVisible(target) { effects += show(workspace: target) }
            effects += focus(id, warp: true)
        } else if focusedWindow == id {
            if isVisible(target) {
                effects += focus(id, warp: false)
            } else {
                focusedWindow = nil
                effects += focusFallback(preferring: source, warp: true)
            }
        }
        collectGarbage()
        return effects
    }

    func switchTo(workspace target: WorkspaceID, onCurrentMonitor: Bool) -> [Effect] {
        if onCurrentMonitor, let current = focusedMonitor {
            if let existing = workspaces[target], existing.monitorID != current.id,
               let other = monitor(id: existing.monitorID) {
                let wasActiveThere = monitorStates[other.id]?.activeWorkspace == target
                let mine = monitorStates[current.id]?.activeWorkspace
                reassign(workspace: target, to: current, from: other)
                if wasActiveThere, let mine, mine != target {
                    // swap: the other monitor takes over what this one showed
                    reassign(workspace: mine, to: other, from: current)
                    monitorStates[other.id]?.activeWorkspace = mine
                }
            } else if workspaces[target] == nil {
                createWorkspace(target, on: current.id)
            }
        }
        let workspace = ensureWorkspace(target)
        let alreadyFocused = focusedWorkspaceID == target
        var effects = show(workspace: target)
        guard !alreadyFocused || focusedWindow.flatMap({ windows[$0]?.workspace }) != target else { return effects }
        if let id = workspace.lastFocused.flatMap({ windows[$0]?.workspace == target ? $0 : nil }) ?? mostRecent(on: target) {
            effects += focus(id, warp: true)
        } else {
            if focusedWindow != nil {
                focusedWindow = nil
                emit(.activeWindow(nil, bundleID: "", title: ""))
            }
            if let monitor = monitor(id: workspace.monitorID), cursor.map({ !monitor.frame.contains($0) }) ?? false,
               config.followMouse == 1, !config.noWarps {
                effects.append(.warpCursor(monitor.visibleFrame.center))
                cursor = monitor.visibleFrame.center
            }
        }
        return effects
    }

    func focusMonitor(_ monitor: Monitor) -> [Effect] {
        guard let state = monitorStates[monitor.id] else { return [] }
        setFocusedMonitor(monitor.id)
        let id = state.special.map { WorkspaceID.special($0) } ?? state.activeWorkspace
        if let window = workspaces[id]?.lastFocused.flatMap({ windows[$0]?.workspace == id ? $0 : nil }) ?? mostRecent(on: id) {
            return focus(window, warp: true)
        }
        if focusedWindow != nil {
            focusedWindow = nil
            emit(.activeWindow(nil, bundleID: "", title: ""))
        }
        if !config.noWarps {
            cursor = monitor.visibleFrame.center
            return [.warpCursor(monitor.visibleFrame.center)]
        }
        return []
    }

    /// Open (`show == true`), close (`false`) or toggle (`nil`) a special
    /// workspace on the focused monitor.
    func toggleSpecial(_ name: String, show wanted: Bool?) -> [Effect] {
        guard let monitor = focusedMonitor else { return [] }
        let id = WorkspaceID.special(name)
        let openHere = monitorStates[monitor.id]?.special == name
        let open = wanted ?? !openHere
        var effects: [Effect] = []
        if open {
            if let existing = workspaces[id], existing.monitorID != monitor.id, let from = self.monitor(id: existing.monitorID) {
                reassign(workspace: id, to: monitor, from: from)
            } else if workspaces[id] == nil {
                createWorkspace(id, on: monitor.id)
            }
            effects += show(workspace: id)
            if let window = workspaces[id]?.lastFocused.flatMap({ windows[$0]?.workspace == id ? $0 : nil }) ?? mostRecent(on: id) {
                effects += focus(window, warp: true)
            }
        } else if openHere {
            monitorStates[monitor.id]?.special = nil
            emit(.activeSpecial(nil, monitorName: monitor.name))
            collectGarbage()
            if let focused = focusedWindow, windows[focused]?.workspace == id { focusedWindow = nil }
            effects += focusFallback(preferring: monitorStates[monitor.id]?.activeWorkspace, warp: true)
        }
        return effects
    }

    func moveWorkspace(_ id: WorkspaceID, to target: Monitor) -> [Effect] {
        guard let workspace = workspaces[id], workspace.monitorID != target.id,
              let source = monitor(id: workspace.monitorID) else { return [] }
        let wasActive = monitorStates[source.id]?.activeWorkspace == id
        reassign(workspace: id, to: target, from: source)
        if case .numbered = id {
            monitorStates[target.id]?.activeWorkspace = id
            if wasActive {
                let replacement = workspaces.values
                    .filter { $0.monitorID == source.id && !$0.id.isSpecial }
                    .map(\.id).sorted().first ?? .numbered(nextFreeNumber())
                if workspaces[replacement] == nil { createWorkspace(replacement, on: source.id) }
                monitorStates[source.id]?.activeWorkspace = replacement
            }
        } else if case .special(let name) = id {
            if monitorStates[source.id]?.special == name { monitorStates[source.id]?.special = nil }
            monitorStates[target.id]?.special = name
        }
        setFocusedMonitor(target.id)
        collectGarbage()
        if let window = workspaces[id]?.lastFocused { return focus(window, warp: true) }
        return []
    }

    /// hd.dsp.retile: every window gets its window rules again as if it had
    /// just opened (float or tile, workspace, floating size and position,
    /// fullscreen, tags, borders), then every workspace's layout is rebuilt
    /// from its tiled windows, in their current order, with default splits.
    func retile() -> [Effect] {
        var effects: [Effect] = []
        // measured again from scratch, in case an app once refused a size it now accepts
        forgetLearnedMinimums()
        for id in windows.keys.sorted() {
            guard let window = windows[id] else { continue }
            let rules = RuleEngine.effects(for: window, rules: config.windowRules)
            windows[id]?.tags = Set(rules.tags)
            // windows the app does not let us resize always float
            if let float = window.info.isResizable ? rules.float : true { setFloating(id, float) }
            if let mode = rules.fullscreen, window.fullscreen != mode {
                exitFullscreen(on: window.workspace)
                windows[id]?.fullscreen = mode
            }
            if let target = rules.workspace?.workspace, target != window.workspace {
                effects += move(id, to: target, follow: false)
            }
            if rules.size != nil || rules.move != nil || rules.center == true, let current = windows[id],
               let monitor = workspaces[current.workspace].flatMap({ self.monitor(id: $0.monitorID) }) {
                windows[id]?.floatingFrame = initialFloatingFrame(for: current, effects: rules, on: monitor)
            }
            applyDynamicRules(to: id)
        }
        for (id, workspace) in workspaces {
            guard let area = tilingArea(for: id) else { continue }
            let tiled = Set(windows.values.filter { $0.workspace == id && !$0.isFloating }.map(\.id))
            let order = workspace.layout.windows.filter(tiled.contains) + tiled.subtracting(workspace.layout.windows).sorted()
            workspaces[id]?.layout = workspace.layout.rebuilt(order, area: area, options: config.layoutOptions)
        }
        effects.append(.rewriteAll)
        return effects
    }

    /// Hyprland's cyclenext: focus (and raise) the next window of the focused
    /// workspace, optionally only floating or only tiled ones. Windows that
    /// float because they do not fit count as floating.
    func cycleWindows(_ filter: CycleFilter, reverse: Bool) -> [Effect] {
        guard let workspace = focusedWorkspaceID else { return [] }
        let plan = computePlan()
        let candidates = windows.values.filter { window in
            guard window.workspace == workspace, plan.frame(of: window.id) != nil else { return false }
            let floating = window.isFloating || plan.overflow.contains(window.id)
            switch filter {
            case .all: return true
            case .floating: return floating
            case .tiled: return !floating
            }
        }.map(\.id).sorted()
        guard !candidates.isEmpty else { return [] }
        let target: WindowID
        if let focused = focusedWindow, let index = candidates.firstIndex(of: focused) {
            target = candidates[((index + (reverse ? -1 : 1)) % candidates.count + candidates.count) % candidates.count]
        } else {
            target = reverse ? candidates.last! : candidates.first!
        }
        guard target != focusedWindow else { return [.focus(target)] }
        return focus(target, warp: true)
    }

    func layoutMessage(_ message: String) -> [Effect] {
        guard let id = focusedWorkspaceID, var workspace = workspaces[id], let area = tilingArea(for: id) else { return [] }
        let focused = focusedWindow.flatMap { windows[$0]?.workspace == id ? $0 : nil }
        let result = workspace.layout.message(message, focused: focused, area: area, options: config.layoutOptions)
        workspaces[id] = workspace
        if let error = result.error { return [.failed(error)] }
        if let target = result.focus { return focus(target, warp: true) }
        return []
    }

    /// Visible windows with their planned frames (tiled first, floating on top).
    func visibleFrames(_ plan: Plan) -> [(id: WindowID, frame: CGRect)] {
        plan.placements.compactMap { id, placement in
            if case .frame(let frame) = placement { return (id, frame) }
            return nil
        }
    }

    func focusInDirection(_ direction: Direction) -> [Effect] {
        let plan = computePlan()
        let candidates = visibleFrames(plan).filter { $0.id != focusedWindow }
        let origin: CGRect
        if let id = focusedWindow, let frame = plan.frame(of: id) {
            origin = frame
        } else if let monitor = focusedMonitor {
            let c = monitor.visibleFrame.center
            origin = CGRect(x: c.x, y: c.y, width: 0, height: 0)
        } else {
            return []
        }
        if let target = Neighbor.find(from: origin, direction: direction, among: candidates) {
            return focus(target, warp: true)
        }
        if let monitor = resolve(monitor: .direction(direction)) {
            return focusMonitor(monitor)
        }
        return []
    }

    func tiledNeighbor(of id: WindowID, direction: Direction, plan: Plan) -> WindowID? {
        guard let frame = plan.frame(of: id) else { return nil }
        let candidates = visibleFrames(plan).filter { candidate in
            candidate.id != id && !plan.overflow.contains(candidate.id)
                && windows[candidate.id].map { !$0.isFloating && $0.fullscreen == nil } == true
        }
        return Neighbor.find(from: frame, direction: direction, among: candidates)
    }

    func swapInDirection(_ direction: Direction) -> [Effect] {
        guard let id = focusedWindow, let window = windows[id], !window.isFloating else { return [] }
        let plan = computePlan()
        guard let other = tiledNeighbor(of: id, direction: direction, plan: plan) else { return [] }
        swapWindows(id, other)
        return focus(id, warp: true)
    }

    func moveInDirection(_ direction: Direction) -> [Effect] {
        guard let id = focusedWindow, let window = windows[id] else { return [] }
        if window.isFloating {
            guard let area = monitorArea(of: window) else { return [] }
            var frame = window.floatingFrame
            let gaps = gapsOut(for: window.workspace)
            switch direction {
            case .left: frame.origin.x = area.minX + gaps.left
            case .right: frame.origin.x = area.maxX - gaps.right - frame.width
            case .up: frame.origin.y = area.minY + gaps.top
            case .down: frame.origin.y = area.maxY - gaps.bottom - frame.height
            }
            windows[id]?.floatingFrame = frame.integral
            return [.focus(id)]
        }
        let plan = computePlan()
        if let other = tiledNeighbor(of: id, direction: direction, plan: plan), windows[other]?.workspace == window.workspace {
            workspaces[window.workspace]?.layout.swap(id, other)
            return focus(id, warp: true)
        }
        // nothing that way on this workspace: hop to the next monitor
        guard let current = workspaces[window.workspace].flatMap({ monitor(id: $0.monitorID) }) else { return [] }
        let others = monitors.filter { $0.id != current.id }.map { (id: $0.id, frame: $0.frame) }
        guard let targetID = Neighbor.find(from: current.frame, direction: direction, among: others),
              let state = monitorStates[targetID] else { return [] }
        return move(id, to: state.special.map { .special($0) } ?? state.activeWorkspace, follow: true)
    }

    func resizeFocused(x: Double, y: Double, relative: Bool) -> [Effect] {
        guard let id = focusedWindow, let window = windows[id] else { return [] }
        if window.isFloating {
            var frame = window.floatingFrame
            if relative {
                frame.size.width = max(50, frame.width + x)
                frame.size.height = max(50, frame.height + y)
            } else {
                frame.size = CGSize(width: max(50, x), height: max(50, y))
            }
            windows[id]?.floatingFrame = frame.integral
            return []
        }
        guard let area = tilingArea(for: window.workspace) else { return [] }
        var dx = x
        var dy = y
        if !relative, let current = computePlan().frame(of: id) {
            dx = x - current.width
            dy = y - current.height
        }
        workspaces[window.workspace]?.layout.resize(id, dx: dx, dy: dy, area: area, options: config.layoutOptions)
        return []
    }

    // MARK: - Pointer and lifecycle helpers

    /// Exchange two tiled windows' places, on one workspace or across two.
    public func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard a != b, let first = windows[a], let second = windows[b], !first.isFloating, !second.isFloating else { return }
        if first.workspace == second.workspace {
            workspaces[first.workspace]?.layout.swap(a, b)
            return
        }
        workspaces[first.workspace]?.layout.replace(a, with: b)
        workspaces[second.workspace]?.layout.replace(b, with: a)
        windows[a]?.workspace = second.workspace
        windows[b]?.workspace = first.workspace
        if workspaces[first.workspace]?.lastFocused == a { workspaces[first.workspace]?.lastFocused = b }
        if workspaces[second.workspace]?.lastFocused == b { workspaces[second.workspace]?.lastFocused = a }
        emit(.moveWindow(a, workspace: second.workspace))
        emit(.moveWindow(b, workspace: first.workspace))
    }

    /// follow_mouse: the cursor entered a visible window.
    public func focusFromCursor(_ id: WindowID) -> [Effect] {
        guard config.followMouse == 1, focusedWindow != id, let window = windows[id], isVisible(window.workspace) else { return [] }
        markFocused(id)
        return [.focus(id)]
    }

    /// The visible window under `point`: floating and fullscreen windows
    /// first (they sit on top), then tiles.
    public func window(at point: CGPoint, plan: Plan) -> WindowID? {
        let visible = visibleFrames(plan).filter { $0.frame.contains(point) }
        let onTop = visible.filter {
            plan.overflow.contains($0.id) || windows[$0.id].map { $0.isFloating || $0.fullscreen != nil } == true
        }
        if let focused = focusedWindow, onTop.contains(where: { $0.id == focused }) { return focused }
        return (onTop.first ?? visible.first)?.id
    }

    /// Frames that bring every parked window back on screen (pause and quit).
    public func revealFrames() -> [WindowID: CGRect] {
        let plan = computePlan()
        var result: [WindowID: CGRect] = [:]
        var cascade = 0.0
        for window in windows.values.sorted(by: { $0.id < $1.id }) {
            guard case .hidden? = plan.placements[window.id] else { continue }
            let monitor = workspaces[window.workspace].flatMap { self.monitor(id: $0.monitorID) } ?? monitors.first
            guard let area = monitor?.visibleFrame else { continue }
            var frame = window.isFloating ? window.floatingFrame : CGRect(origin: .zero, size: window.info.frame.size)
            if !window.isFloating || !area.intersects(frame) {
                frame.origin = CGPoint(x: area.minX + 40 + cascade, y: area.minY + 40 + cascade)
                cascade = (cascade + 30).truncatingRemainder(dividingBy: 300)
            }
            result[window.id] = clamp(frame, to: area).integral
        }
        return result
    }
}
