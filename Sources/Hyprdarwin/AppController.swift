import AppKit
import HyprdarwinConfig
import HyprdarwinControl
import HyprdarwinCore
import HyprdarwinIPC

/// Wires the pure model to the system: window source -> model -> plan ->
/// applier, event tap -> binds -> dispatchers, config watcher -> reloads,
/// IPC sockets (hyprdarwinctl requests, the event stream), menu bar and the
/// read-only settings window. Everything here runs on the main thread.
final class AppController {
    let model = WindowManager()
    private let source = WindowSource()
    private lazy var applier = FrameApplier(source: source)
    private let input = EventTap()
    private let watcher = ConfigWatcher()
    private let menu = MenuBarController()
    private let banner = ErrorBanner()
    private let settings = SettingsWindow()
    private let borders = BorderController()
    private let ipc = IPCService()

    private(set) var activeConfig = Config()
    private(set) var messages: [ConfigMessage] = []
    private var runtime: LuaConfigRuntime?
    private var configFailed = false
    /// No config file ever loaded: the built-in default config is active.
    private var runningDefaults = false
    private var pendingLoadActions: [RuntimeAction] = []
    private var startCallbacksFired = false
    private var configFiles: [String] = []
    private var lastLoad: Date?
    /// While a hyprdarwinctl dispatch runs: the dispatchers that failed.
    private var dispatchFailures: [String]?

    private var managing = false
    private var paused = false
    private var capsRemapped = false
    private var known: [pid_t: Set<WindowID>] = [:]
    private var lastPlan = Plan()
    private var lastOSFocus: WindowID?
    private var focusTracker = FocusTracker()
    private var listingProbe = ListingProbe()
    private var probeTimer: Timer?
    private var lastWorkspaceChange = Date.distantPast
    private var lastHoverCheck = Date.distantPast
    private var trustTimer: Timer?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Lifecycle

    func launch() {
        Log.info("hyprdarwin \(BuildInfo.current) starting (pid \(ProcessInfo.processInfo.processIdentifier)), config \(watcher.path)")
        menu.onReload = { [weak self] in self?.reloadConfig() }
        menu.onOpenConfig = { [weak self] in self?.openConfig() }
        menu.onShowMessages = { [weak self] in self?.showSettings(.errors) }
        menu.onShowSettings = { [weak self] in self?.showSettings(nil) }
        menu.onTogglePause = { [weak self] in self?.togglePause() }
        menu.onOpenAccessibilitySettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        menu.onQuit = { NSApp.terminate(nil) }
        menu.onAbout = {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationVersion: BuildInfo.current.description,
                .version: "",
            ])
        }
        banner.onClick = { [weak self] in self?.showSettings(.errors) }
        settings.onReload = { [weak self] in self?.reloadConfig() }
        settings.onOpenConfig = { [weak self] in self?.openConfig() }
        watcher.onChange = { [weak self] in self?.reloadConfig() }
        ipc.onRequest = { [weak self] request, reply in
            reply(self?.answer(request) ?? IPCReply.error("hyprdarwin is shutting down"))
        }

        // before the config loads, so its exec_cmd calls inherit the signature
        ipc.start()
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
        applier.onSizeRefused = { [weak self] id, wanted in self?.sizeRefused(id, wanted: wanted) }
        input.onBind = { [weak self] index in self?.runBind(index) }
        input.start()
        source.onEvent = { [weak self] event in self?.handle(event) }
        source.start()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.mouseMoved() }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.probeListings() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.info("displays changed")
            self.model.setMonitors(Monitors.current())
            self.refresh()
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { focusTracker.noteKeyboard(pid: pid, window: nil, model: model) }
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard let self else { return }
            self.focusTracker.noteKeyboard(pid: app.processIdentifier, window: nil, model: self.model)
        })
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
        probeTimer?.invalidate()
        borders.hideAll()
        if managing && !paused { revealParkedWindows() }
        if capsRemapped { KeyRemapper.remove() }
        input.stop()
        source.stop()
        watcher.stop()
        ipc.stop()
        Log.info("hyprdarwin stopped")
    }

    // MARK: - Config

    func reloadConfig() {
        let result = ConfigLoader.load(path: watcher.path)
        messages = result.messages
        configFiles = result.files
        lastLoad = Date()
        if let config = result.config {
            configFailed = false
            runningDefaults = false
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
                if let config = fallback.config {
                    install(config, runtime: fallback.runtime)
                    runningDefaults = true
                }
                messages.append(ConfigMessage(.info, "using the built-in default config until the error above is fixed"))
            }
        }
        for message in messages where message.severity != .error {
            Log.info("config \(message.severity.rawValue): \(message.text)")
        }
        updateBanner()
        refresh()
        updateMenu()
        updateSettings()
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

    private func showSettings(_ tab: SettingsTab?) {
        updateSettings(force: true)
        settings.show(tab: tab)
    }

    /// The settings window shows the active config, as amended at runtime
    /// (bind and rule handles toggled by Lua).
    private func updateSettings(force: Bool = false) {
        guard force || settings.isOpen else { return }
        var status = SettingsState.Status.loaded
        if configFailed { status = runningDefaults ? .failed : .rejected }
        settings.update(SettingsState(
            configPath: watcher.path, files: configFiles, loadedAt: lastLoad, status: status,
            report: ConfigReport(config: activeConfig), messages: messages))
    }

    // MARK: - IPC

    /// One hyprdarwinctl request.
    private func answer(_ request: IPCRequest) -> String {
        switch ControlCommand(request) {
        case let .query(query, json):
            let context = QueryContext(model: model, config: activeConfig, messages: messages, build: BuildInfo.current)
            return query.reply(json: json, context: context)
        case .dispatch(let code):
            guard !code.isEmpty else { return IPCReply.error("dispatch needs a dispatcher, e.g. hyprdarwinctl dispatch 'hl.dsp.focus({ workspace = 2 })'") }
            guard managing else { return IPCReply.error("not managing windows yet (waiting for the Accessibility permission)") }
            guard !paused else { return IPCReply.error("hyprdarwin is paused") }
            guard let runtime else { return IPCReply.error("no config is loaded") }
            let outcome = runtime.evaluate(code)
            for message in outcome.messages { Log.info("dispatch: \(message.text)") }
            if let error = outcome.error { return IPCReply.error(error) }
            Log.info("dispatch from hyprdarwinctl: \(code)")
            dispatchFailures = []
            run(outcome.actions)
            let failures = dispatchFailures ?? []
            dispatchFailures = nil
            return failures.isEmpty ? IPCReply.ok : IPCReply.error(failures.joined(separator: "; "))
        case .reload:
            reloadConfig()
            guard configFailed else { return IPCReply.ok }
            let reason = messages.first { $0.severity == .error }?.text ?? "unknown error"
            return IPCReply.error("config rejected, keeping the previous one: \(reason)")
        case .unknown:
            return IPCReply.unknownRequest
        }
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
            updateSettings()
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
        // a bind or rule handle was toggled: the settings window shows it
        if actions.contains(where: { if case .dispatch = $0 { false } else { true } }) { updateSettings() }
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
            case let .activate(pid, window):
                Log.info("giving the keyboard back to pid \(pid) window \(window.map(String.init) ?? "-")")
                lastOSFocus = window
                if pid == ProcessInfo.processInfo.processIdentifier {
                    NSApp.activate()
                } else if window.map({ SkyLight.makeKeyWindow(pid: pid, windowID: $0) }) != true {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
            case .warpCursor(let point):
                CGWarpMouseCursorPosition(point)
                CGAssociateMouseAndMouseCursorPosition(1)
            case .submap(let name):
                input.setSubmap(name)
                Log.info("submap: \(name.isEmpty ? "reset" : name)")
            case .reload:
                reloadConfig()
            case .rewriteAll:
                // re-tile: write every window again, even ones the applier had
                // accepted elsewhere, and re-list every app's windows
                Log.info("re-tile: rewriting every window")
                applier.reset()
                source.refreshAll()
            case .exit:
                NSApp.terminate(nil)
            case .failed(let message):
                Log.info("dispatch failed: \(message)")
                dispatchFailures?.append(message)
            }
        }
    }

    // MARK: - Window source

    private func handle(_ event: WorkerEvent) {
        guard managing else { return }
        switch event {
        case let .windows(pid, infos, away, initial):
            let changes = model.applyListing(infos, away: away, previous: known[pid] ?? [], initial: initial)
            let has = Set(infos.map(\.id)).union(away)
            known[pid] = has.isEmpty ? nil : has
            var returned = false
            for change in changes {
                switch change {
                case let .replaced(old, new):
                    focusTracker.forget(old)
                    let info = model.windows[new]?.info
                    Log.info("window \(old) became \(new) (tab switch): \(info?.bundleID ?? "") \"\(info?.title ?? "")\"")
                case let .removed(id, effects):
                    focusTracker.forget(id)
                    Log.info("window \(id) removed: its app no longer lists it")
                    perform(effects)
                case .away(let id):
                    Log.info("window \(id) is on another Space: keeping its place")
                case .returned(let id):
                    Log.info("window \(id) is back from another Space")
                    returned = true
                case let .added(id, isNew, effects):
                    if let info = model.windows[id]?.info {
                        Log.info("window \(id) \(isNew ? "opened" : "found"): \(info.bundleID) \"\(info.title)\" \(info.subrole)")
                    }
                    perform(effects)
                    if isNew { opened(id) }
                }
            }
            if returned, model.focusedWindow == nil {
                // back on this Space: the keyboard may already be on a
                // returning window, keyed while it was still away
                lastOSFocus = nil
                source.reportFrontmostFocus()
            }
        case let .destroyed(pid, id):
            known[pid]?.remove(id)
            focusTracker.forget(id)
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
            focusTracker.noteKeyboard(pid: pid, window: id, model: model)
            handleOSFocus(id, pid: pid)
        case .applied(let results):
            // our own write read back: the real frame, never a user move
            for (id, frame) in results { model.windowFrameChanged(id, frame: frame) }
            applier.applied(results)
            updateBorders()
            return
        }
        refresh()
    }

    private func opened(_ id: WindowID) {
        let effects = focusTracker.opened(id, model: model)
        perform(effects)
        guard effects.isEmpty else { return }
        // the keyboard may be on it with no focus event to say so, or with one
        // that came too long before it was listed: ask the frontmost app now,
        // and again once it is keyed
        lastOSFocus = nil
        source.reportFrontmostFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.managing else { return }
            self.source.reportFrontmostFocus()
        }
    }

    private func handleOSFocus(_ id: WindowID?, pid: pid_t) {
        guard let id, id != lastOSFocus else { return }
        lastOSFocus = id
        // a stale notification from the workspace we just left must not pull us back
        if let window = model.windows[id], !model.isVisible(window.workspace),
           Date().timeIntervalSince(lastWorkspaceChange) < 0.5 { return }
        let step = focusTracker.osFocus(id, pid: pid, model: model)
        perform(step.effects)
        guard let delay = step.recheckAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.managing else { return }
            self.perform(self.focusTracker.switchDue(model: self.model, keyboardOn: self.lastOSFocus))
            self.refresh()
        }
    }

    /// A window came or went without its app saying so: that app re-lists
    /// its windows now instead of at the next periodic re-list (ListingProbe).
    private func probeListings() {
        guard managing else { return }
        // windows on another Space are not on screen, and their app is not listing them
        let listed = Dictionary(uniqueKeysWithValues: source.pids.map { pid in
            (pid, (known[pid] ?? []).filter { model.windows[$0]?.isAway != true })
        })
        for pid in listingProbe.appsToRelist(listed: listed, onScreen: WindowStack.onScreenWindows(), now: Date()) {
            source.refresh(pid: pid)
        }
    }

    /// An app kept a window larger than asked. Readback right after a write
    /// can be stale, so look again once the window has settled (resize
    /// notifications keep its frame current) before taking it as a minimum.
    private func sizeRefused(_ id: WindowID, wanted: CGSize) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.managing, !self.paused, let window = self.model.windows[id],
                  let minimum = self.model.windowKeptSize(id, wanted: wanted, plan: self.lastPlan) else { return }
            let limits = [minimum.width > 0 ? "\(Int(minimum.width)) wide" : nil, minimum.height > 0 ? "\(Int(minimum.height)) tall" : nil]
            Log.info("window \(id) (\(window.info.bundleID)) will not shrink below \(limits.compactMap { $0 }.joined(separator: " or ")); tiling around it")
            self.refresh()
        }
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
        var lines: [String] = []
        for event in model.drainEvents() {
            let eventLines = model.eventLines(event)
            Log.debug("event \(eventLines.joined(separator: " | "))")
            lines += eventLines
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
        }
        ipc.publish(lines)
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

    /// `kill -USR1 <pid>` writes the model state to the log, including what
    /// hidden workspaces would look like (more than hyprdarwinctl shows).
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
            let minimum = window.minimumSize
            let minText = minimum == .zero ? "" : " min \(Int(minimum.width))x\(Int(minimum.height))"
            var mode = window.isFloating ? "floating" : plan.overflow.contains(window.id) ? "tiled (overflow, floating on top)" : "tiled"
            if window.isAway { mode += " (away on another Space)" }
            lines.append("  window \(window.id) \(window.info.bundleID) \"\(window.info.title)\" ws \(window.workspace) \(mode)\(minText) planned \(placement) actual \(FrameApplier.describe(window.info.frame))\(window.id == model.focusedWindow ? " (focused)" : "")")
        }
        Log.info(lines.joined(separator: "\n"))
    }
}
