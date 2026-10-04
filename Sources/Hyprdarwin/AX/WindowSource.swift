import AppKit
import HyprdarwinCore

/// Owns one AppWorker per regular app and follows app launches, quits,
/// hides and activations. Main-thread only; every event reaches `onEvent`
/// on the main thread.
final class WindowSource {
    var onEvent: ((WorkerEvent) -> Void)?
    private var workers: [pid_t: AppWorker] = [:]
    private var observers: [NSObjectProtocol] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app, initial: true)
        }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                handler(app)
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard app.activationPolicy == .regular else { return }
            self?.attach(app, initial: false)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            self?.detach(app.processIdentifier)
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            self?.workers[app.processIdentifier]?.setHidden(true)
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            self?.workers[app.processIdentifier]?.setHidden(false)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            guard let self else { return }
            // apps that switched to .regular after launch (some Electron apps)
            if self.workers[app.processIdentifier] == nil, app.activationPolicy == .regular {
                self.attach(app, initial: false)
            }
            self.workers[app.processIdentifier]?.reportFocus()
        }
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAll()
        })
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        workers.values.forEach { $0.stop() }
        workers.removeAll()
    }

    func refreshAll() { workers.values.forEach { $0.refresh() } }

    /// Ask the frontmost app which of its windows is focused.
    func reportFrontmostFocus() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        workers[pid]?.reportFocus()
    }

    func setFrames(_ items: [(pid: pid_t, id: WindowID, frame: CGRect, positionOnly: Bool)]) {
        let grouped = Dictionary(grouping: items, by: \.pid)
        for (pid, entries) in grouped {
            workers[pid]?.setFrames(entries.map { ($0.id, $0.frame, $0.positionOnly) })
        }
    }

    /// Write frames and wait (bounded) until every worker is done: used on
    /// quit and pause, when the next step may tear the workers down.
    func setFramesAndWait(_ items: [(pid: pid_t, id: WindowID, frame: CGRect, positionOnly: Bool)], timeout: TimeInterval = 2) {
        let group = DispatchGroup()
        for (pid, entries) in Dictionary(grouping: items, by: \.pid) {
            guard let worker = workers[pid] else { continue }
            group.enter()
            worker.setFrames(entries.map { ($0.id, $0.frame, $0.positionOnly) }) { group.leave() }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    func focus(pid: pid_t, id: WindowID) {
        if !SkyLight.makeKeyWindow(pid: pid, windowID: id) {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        workers[pid]?.raise(id)
    }

    func close(pid: pid_t, id: WindowID) {
        workers[pid]?.close(id)
    }

    private func attach(_ app: NSRunningApplication, initial: Bool) {
        let pid = app.processIdentifier
        guard pid != selfPID, workers[pid] == nil else { return }
        let worker = AppWorker(app: app, initial: initial) { [weak self] event in
            // drop events a worker queued just before its app quit
            guard let self, self.workers[pid] != nil else { return }
            self.onEvent?(event)
        }
        workers[pid] = worker
        worker.start()
    }

    private func detach(_ pid: pid_t) {
        guard let worker = workers.removeValue(forKey: pid) else { return }
        worker.stop()
        onEvent?(.windows(pid: pid, [], initial: false))
    }
}
