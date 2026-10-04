import AppKit
import HyprdarwinConfig
import HyprdarwinCore

/// Wires the pure model to the system: window source -> model -> plan ->
/// applier, event tap -> binds -> dispatchers, config watcher -> reloads,
/// menu bar. Everything here runs on the main thread.
///
/// Seams for the next milestone: `onEvent` is where the IPC event socket and
/// the active border overlay will subscribe; `model` already answers every
/// query the request socket needs; the settings window reads `activeConfig`
/// and `messages`.
final class AppController {
    let model = WindowManager()
    private let source = WindowSource()
    private lazy var applier = FrameApplier(source: source)
    private let input = EventTap()
    private let watcher = ConfigWatcher()
    private let menu = MenuBarController()
    private let banner = ErrorBanner()
    private let messagesWindow = MessagesWindow()
    private let borders = BorderController()

    /// Every model event, in Hyprland's `EVENT>>DATA` vocabulary.
    var onEvent: ((WMEvent) -> Void)?

    private(set) var activeConfig = Config()
    private(set) var messages: [ConfigMessage] = []
    private var runtime: LuaConfigRuntime?
    private var configFailed = false
    private var pendingLoadActions: [RuntimeAction] = []
    private var startCallbacksFired = false

    private var managing = false
    private var paused = false
    private var capsRemapped = false
    private var known: [pid_t: Set<WindowID>] = [:]
    private var lastPlan = Plan()
    private var lastOSFocus: WindowID?
    /// When each window opened, to tell "macOS focused a brand-new window"
    /// apart from the user focusing it.
    private var openedAt: [WindowID: Date] = [:]
    private var lastWorkspaceChange = Date.distantPast
    private var lastHoverCheck = Date.distantPast
    private var trustTimer: Timer?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Lifecycle

    func launch() {
        Log.info("hyprdarwin starting (pid \(ProcessInfo.processInfo.processIdentifier)), config \(watcher.path)")
        menu.onReload = { [weak self] in self?.reloadConfig() }
        menu.onOpenConfig = { [weak self] in self?.openConfig() }
        menu.onShowMessages = { [weak self] in self?.showMessages() }
        menu.onTogglePause = { [weak self] in self?.togglePause() }
        menu.onOpenAccessibilitySettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        menu.onQuit = { NSApp.terminate(nil) }
        banner.onClick = { [weak self] in self?.showMessages() }
        watcher.onChange = { [weak self] in self?.reloadConfig() }

        watcher.createDefaultIfMissing()
        reloadConfig()
        installSignalHandlers()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            startManaging()
        } else {
            Log.info("waiting for the Accessibility permission (System Settings > Privacy & Security > Accessibility)")
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startManaging()
            }
        }
        updateMenu()
    }

    private func startManaging() {
        guard !managing else { return }
        managing = true
        Log.info("Accessibility granted; managing windows")
        model.setMonitors(Monitors.current())
        updateCapsRemap()
        applier.onFloatingMoved = { [weak self] id, frame in self?.model.floatingWindowMoved(id, frame: frame) }
        applier.onUserDrop = { [weak self] id, point in self?.dropped(id, at: point) ?? false }
        input.onBind = { [weak self] index in self?.runBind(index) }
        input.start()
        source.onEvent = { [weak self] event in self?.handle(event) }
        source.start()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.mouseMoved() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.info("displays changed")
            self.model.setMonitors(Monitors.current())
            self.refresh()
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // a key-up can be lost across sleep; and apps may have moved windows
            self.input.resetState()
            self.model.setMonitors(Monitors.current())
            self.applier.reset()
            self.source.refreshAll()
            self.refresh()
        })

        if runtime != nil, !startCallbacksFired {
            startCallbacksFired = true
            if let outcome = runtime?.fire(.start) { absorb(outcome, context: "hyprland.start") }
        }
        let actions = pendingLoadActions
        pendingLoadActions.removeAll()
        run(actions)
        source.reportFrontmostFocus()
        refresh()
    }

    /// Called from applicationWillTerminate: put parked windows back on
    /// screen and give Caps Lock back.
    func shutdown() {
        if let outcome = runtime?.fire(.shutdown) {
            for case .dispatch(.exec(let command)) in outcome.actions {
                Exec.run(command, environment: activeConfig.environment)
            }
        }
        borders.hideAll()
        if managing && !paused { revealParkedWindows() }
        if capsRemapped { KeyRemapper.remove() }
        input.stop()
        source.stop()
        watcher.stop()
        Log.info("hyprdarwin stopped")
    }

    // MARK: - Config

    func reloadConfig() {
        let result = ConfigLoader.load(path: watcher.path)
        messages = result.messages
        if let config = result.config {
            configFailed = false
            install(config, runtime: result.runtime)
            let summary = "\(config.binds.count) binds, \(config.windowRules.count) window rules, \(config.workspaceRules.count) workspace rules"
            Log.info("config loaded from \(watcher.path): \(summary)")
            if managing {
                run(result.actions)
            } else {
                pendingLoadActions = result.actions
            }
        } else {
            configFailed = true
            Log.error("config rejected, keeping the previous one: \(result.errors.first?.text ?? "unknown error")")
            if runtime == nil {
                // nothing loaded yet: run on the built-in defaults so binds still work
                let fallback = ConfigLoader.load(source: DefaultConfig.text)
                if let config = fallback.config { install(config, runtime: fallback.runtime) }
                messages.append(ConfigMessage(.info, "using the built-in default config until the error above is fixed"))
            }
        }
        for message in messages where message.severity != .error {
            Log.info("config \(message.severity.rawValue): \(message.text)")
        }
        updateBanner()
        refresh()
        updateMenu()
    }

    private func install(_ config: Config, runtime newRuntime: LuaConfigRuntime?) {
        let unmanagedChanged = config.unmanagedApps != activeConfig.unmanagedApps
        activeConfig = config
        runtime = newRuntime
        let released = model.setConfig(config)
        if managing && !paused {
            source.setFrames(released.map { ($0.info.pid, $0.info.id, $0.frame, false) })
            // windows of apps no longer unmanaged are adopted on the next snapshot
            if unmanagedChanged { source.refreshAll() }
        }
        input.update(binds: config.binds, hyprKey: config.hyprKey)
        input.setSubmap(model.submap)
        updateCapsRemap()
        if config.disableAutoreload {
            watcher.stop()
        } else {
            watcher.start()
        }
    }

    private func updateBanner() {
        let errors = messages.filter { $0.severity == .error }
        let warnings = messages.filter { $0.severity == .warning }
        if let first = errors.first {
            banner.show(error: first.text, extra: errors.count - 1 + warnings.count)
        } else if let first = warnings.first {
            banner.show(warning: first.text, extra: warnings.count - 1)
        } else {
            banner.hide()
        }
    }

    private func openConfig() {
        let url = URL(fileURLWithPath: watcher.path)
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func showMessages() {
        messagesWindow.show(messages: messages, path: watcher.path)
    }

    // MARK: - Binds and dispatch

    private func runBind(_ index: Int) {
        guard managing, !paused, activeConfig.binds.indices.contains(index) else { return }
        let bind = activeConfig.binds[index]
        Log.debug("bind \(bind.combo)")
        switch bind.action {
        case .dispatcher(let dispatcher):
            dispatch(dispatcher)
        case .luaFunction(let ref):
            guard let outcome = runtime?.call(function: ref) else { return }
            absorb(outcome, context: "bind \(bind.combo)")
        }
    }

    private func absorb(_ outcome: CallOutcome, context: String) {
        for message in outcome.messages { Log.info("\(context): \(message.text)") }
        if let error = outcome.error {
            Log.error("\(context): \(error)")
            messages.append(ConfigMessage(.warning, "\(context): \(error)"))
            banner.show(warning: "\(context): \(error)", extra: 0)
            updateMenu()
        }
        run(outcome.actions)
    }

    private func run(_ actions: [RuntimeAction]) {
        for action in actions {
            switch action {
            case .dispatch(let dispatcher):
                dispatch(dispatcher)
            case let .setWindowRuleEnabled(index, enabled):
                guard activeConfig.windowRules.indices.contains(index) else { continue }
                activeConfig.windowRules[index].enabled = enabled
                model.setWindowRuleEnabled(index, enabled)
            case let .setBindEnabled(index, enabled):
                guard activeConfig.binds.indices.contains(index) else { continue }
                activeConfig.binds[index].enabled = enabled
                input.update(binds: activeConfig.binds, hyprKey: activeConfig.hyprKey)
            }
        }
        refresh()
    }

    private func dispatch(_ dispatcher: Dispatcher) {
        guard managing else { return }
        Log.debug("dispatch \(dispatcher)")
        perform(model.dispatch(dispatcher))
        refresh()
    }

    private func perform(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case .exec(let command):
                Exec.run(command, environment: activeConfig.environment)
            case .close(let id):
                if let pid = model.windows[id]?.info.pid { source.close(pid: pid, id: id) }
            case .kill(let pid):
                NSRunningApplication(processIdentifier: pid)?.forceTerminate()
            case .focus(let id):
                guard let window = model.windows[id] else { continue }
                let pid = window.info.pid
                Log.info("focusing window \(id) (\(window.info.bundleID))")
                lastOSFocus = id
                source.focus(pid: pid, id: id)
            case .warpCursor(let point):
                CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
            case .submap(let name):
                input.setSubmap(name)
                Log.info("submap: \(name.isEmpty ? "reset" : name)")
            case .reload:
                reloadConfig()
            case .exit:
                NSApp.terminate(nil)
            case .failed(let message):
                Log.info("dispatch failed: \(message)")
            }
        }
    }

    // MARK: - Window source

    private func handle(_ event: WorkerEvent) {
        guard managing else { return }
        switch event {
        case let .windows(pid, infos, initial):
            let previous = known[pid] ?? []
            let current = Set(infos.map(\.id))
            var gone = previous.subtracting(current).filter { model.windows[$0] != nil }
            for info in infos where !previous.contains(info.id) && model.windows[info.id] == nil {
                // switching native tabs swaps one tab window for another at the
                // same frame: keep its place instead of closing and reopening
                guard let old = gone.first(where: { model.windows[$0]?.info.frame.isClose(to: info.frame, tolerance: 4) == true }) else { continue }
                gone.remove(old)
                model.replaceWindow(old, with: info)
                openedAt[old] = nil
                Log.info("window \(old) became \(info.id) (tab switch): \(info.bundleID) \"\(info.title)\"")
            }
            for id in previous.subtracting(current) where model.windows[id] != nil {
                perform(model.removeWindow(id))
            }
            for info in infos {
                if model.windows[info.id] != nil {
                    model.updateInfo(info)
                } else if activeConfig.unmanagedApps.contains(info.bundleID) {
                    continue
                } else {
                    // a window seen before (its app was unmanaged) is adopted, not opened
                    let isNew = !initial && !previous.contains(info.id)
                    Log.info("window \(info.id) \(isNew ? "opened" : "found"): \(info.bundleID) \"\(info.title)\" \(info.subrole)")
                    if isNew { openedAt[info.id] = Date() }
                    perform(model.addWindow(info, isNew: isNew))
                }
            }
            known[pid] = current.isEmpty ? nil : current
        case let .destroyed(pid, id):
            known[pid]?.remove(id)
            openedAt[id] = nil
            if model.windows[id] != nil { Log.info("window \(id) closed") }
            perform(model.removeWindow(id))
        case let .frame(id, frame):
            applier.observed(id, frame: frame, model: model)
            model.windowFrameChanged(id, frame: frame)
            updateBorders()
            return
        case let .title(id, title):
            guard var info = model.windows[id]?.info else { return }
            info.title = title
            model.updateInfo(info)
        case let .focused(pid, id):
            // background apps change their own focused window too; only the
            // frontmost app's focus is the keyboard's (activation re-reports it)
            guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
            handleOSFocus(id)
        case .applied(let results):
            // our own write read back: the real frame, never a user move
            for (id, frame) in results { model.windowFrameChanged(id, frame: frame) }
            applier.applied(results)
            updateBorders()
            return
        }
        refresh()
    }

    private func handleOSFocus(_ id: WindowID?) {
        guard let id, id != lastOSFocus else { return }
        lastOSFocus = id
        guard let window = model.windows[id], id != model.focusedWindow else { return }
        // a stale notification from the workspace we just left must not pull us back
        if !model.isVisible(window.workspace), Date().timeIntervalSince(lastWorkspaceChange) < 0.5 { return }
        let justOpened = openedAt[id].map { Date().timeIntervalSince($0) < 2 } ?? false
        if justOpened, !activeConfig.focusOnOpen, !model.isVisible(window.workspace) {
            Log.info("window \(id) opened on hidden workspace \(window.workspace); staying put (misc.focus_on_open is off)")
        }
        perform(model.externalFocus(id, justOpened: justOpened))
    }

    /// A tiled window dragged onto another tile swaps with it.
    private func dropped(_ id: WindowID, at point: CGPoint) -> Bool {
        guard model.windows[id]?.isFloating == false,
              let target = model.window(at: point, plan: lastPlan), target != id,
              model.windows[target]?.isFloating == false else { return false }
        Log.info("window \(id) dropped on \(target): swapping")
        model.swapWindows(id, target)
        refresh()
        return true
    }

    private func mouseMoved() {
        guard managing, !paused else { return }
        let point = FrameApplier.cursorLocation()
        model.cursor = point
        guard activeConfig.followMouse == 1, NSEvent.pressedMouseButtons == 0 else { return }
        guard let id = model.window(at: point, plan: lastPlan), id != model.focusedWindow else { return }
        guard Date().timeIntervalSince(lastHoverCheck) > 0.05 else { return }
        lastHoverCheck = Date()
        // only when nothing (a menu, a panel, an unmanaged window) covers it
        guard WindowStack.topmostNormalWindow(at: point) == id else { return }
        perform(model.focusFromCursor(id))
        refresh()
    }

    private func refresh() {
        guard managing else { return }
        lastPlan = model.computePlan()
        if !paused { applier.apply(lastPlan, model: model) }
        updateBorders()
        for event in model.drainEvents() {
            Log.debug("event \(event.line)")
            switch event {
            case .workspace, .activeSpecial:
                lastWorkspaceChange = Date()
            case .activeWindow(nil, _, _):
                // nothing to focus (empty workspace). Only if the keyboard is on
                // a window we just hid, take it ourselves so typing cannot reach
                // a hidden window; never take it from an unmanaged app.
                if let os = lastOSFocus, let window = model.windows[os], !model.isVisible(window.workspace) {
                    NSApp.activate()
                    lastOSFocus = nil
                }
            default:
                break
            }
            onEvent?(event)
        }
        updateMenu()
    }

    /// The focused window gets the active border only while it really has
    /// the keyboard (not while an unmanaged app or hyprdarwin itself has it).
    private func updateBorders() {
        guard managing, !paused else {
            borders.hideAll()
            return
        }
        let active = model.focusedWindow.flatMap { $0 == lastOSFocus ? $0 : nil }
        borders.update(model: model, plan: lastPlan, activeWindow: active)
    }

    // MARK: - Pause, Caps Lock, menu

    private func togglePause() {
        guard managing else { return }
        paused.toggle()
        input.setPaused(paused)
        updateCapsRemap()
        if paused {
            revealParkedWindows()
            applier.isEnabled = false
            applier.reset()
            Log.info("paused")
        } else {
            applier.isEnabled = true
            source.refreshAll()
            Log.info("resumed")
        }
        refresh()
    }

    private func revealParkedWindows() {
        let frames = model.revealFrames()
        let items = frames.compactMap { id, frame -> (pid: pid_t, id: WindowID, frame: CGRect, positionOnly: Bool)? in
            guard let pid = model.windows[id]?.info.pid else { return nil }
            return (pid, id, frame, false)
        }
        source.setFramesAndWait(items)
    }

    private func updateCapsRemap() {
        let wanted = managing && !paused && activeConfig.hyprKey == .capsLock
        guard wanted != capsRemapped else { return }
        if wanted { KeyRemapper.install() } else { KeyRemapper.remove() }
        capsRemapped = wanted
    }

    private func updateMenu() {
        var state = MenuBarController.State()
        if !managing {
            state.status = .waitingForAccessibility
        } else if paused {
            state.status = .paused
        } else {
            state.status = configFailed ? .configError : .running
        }
        if let monitor = model.focusedMonitorID, let monitorState = model.monitorStates[monitor] {
            state.workspace = monitorState.activeWorkspace.description
            state.special = monitorState.special
        }
        state.submap = model.submap
        state.messages = messages
        state.configPath = watcher.path
        menu.update(state)
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGUSR1] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                if signalNumber == SIGUSR1 {
                    self?.dumpState()
                } else {
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// `kill -USR1 <pid>` writes the model state to the log (until the
    /// hyprdarwinctl socket exists).
    private func dumpState() {
        var lines = ["state dump:"]
        for monitor in model.monitors {
            let state = model.monitorStates[monitor.id]
            lines.append("  monitor \(monitor.id) \"\(monitor.name)\" \(FrameApplier.describe(monitor.frame)) workspace \(state?.activeWorkspace.description ?? "-")\(state?.special.map { " special:\($0)" } ?? "")\(monitor.id == model.focusedMonitorID ? " (focused)" : "")")
        }
        for workspace in model.workspaces.values.sorted(by: { $0.id < $1.id }) {
            lines.append("  workspace \(workspace.id) on \(workspace.monitorID) layout \(workspace.layout.kind.rawValue) tiled \(workspace.layout.windows)\(model.isVisible(workspace.id) ? " (visible)" : "")")
            if !model.isVisible(workspace.id) {
                for (id, frame) in model.layoutPreview(for: workspace.id).sorted(by: { $0.key < $1.key }) {
                    lines.append("    if shown: window \(id) at \(FrameApplier.describe(frame))")
                }
            }
        }
        let plan = model.computePlan()
        for window in model.windows.values.sorted(by: { $0.id < $1.id }) {
            let placement: String
            switch plan.placements[window.id] {
            case .frame(let rect)?: placement = FrameApplier.describe(rect)
            case .hidden(let origin)?: placement = "parked at (\(Int(origin.x)),\(Int(origin.y)))"
            case nil: placement = "-"
            }
            lines.append("  window \(window.id) \(window.info.bundleID) \"\(window.info.title)\" ws \(window.workspace) \(window.isFloating ? "floating" : "tiled") planned \(placement) actual \(FrameApplier.describe(window.info.frame))\(window.id == model.focusedWindow ? " (focused)" : "")")
        }
        Log.info(lines.joined(separator: "\n"))
    }
}
