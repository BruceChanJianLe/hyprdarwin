// Event-driven discovery through one AXObserver per app, the window-level
// subscriptions, the admitted subroles and the AXEnhancedUserInterface
// workaround follow HyprMac (https://github.com/zacharytgray/HyprMac,
// HyprMac/Core/Discovery/AXNotificationService.swift and
// HyprMac/Models/HyprWindow.swift, MIT License, Copyright (c) 2026 Zachary Gray).
// Running each app's AX work on its own thread is AeroSpace's approach.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import ApplicationServices
import HyprdarwinCore

enum WorkerEvent {
    /// Every manageable window the app has right now.
    case windows(pid: pid_t, [WindowInfo], initial: Bool)
    case destroyed(pid: pid_t, WindowID)
    case frame(WindowID, CGRect)
    case title(WindowID, String)
    case focused(pid: pid_t, WindowID?)
    /// Frames read back after a write batch.
    case applied([WindowID: CGRect])
}

/// All Accessibility work for one app. The app's AXObserver lives on this
/// worker's own thread and run loop, and every AX call into the app runs
/// there too, so an app that hangs stalls only its worker, never the main
/// thread or the keyboard. Events go to `sink` on the main thread.
final class AppWorker {
    let pid: pid_t
    let bundleID: String
    let appName: String

    private let initial: Bool
    private let sink: (WorkerEvent) -> Void
    private var runLoop: CFRunLoop?

    // worker-thread state
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var elements: [WindowID: AXUIElement] = [:]
    private var subscribed: Set<WindowID> = []
    private var reconcileTimer: CFRunLoopTimer?
    private var attachAttempts = 0
    private var sentFirstSnapshot = false
    private var hidden = false

    static let admittedSubroles: Set<String> = [
        "", kAXStandardWindowSubrole as String, kAXDialogSubrole as String,
        kAXSystemDialogSubrole as String, kAXFloatingWindowSubrole as String,
    ]

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
        kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    init(app: NSRunningApplication, initial: Bool, sink: @escaping (WorkerEvent) -> Void) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier ?? ""
        appName = app.localizedName ?? bundleID
        hidden = app.isHidden
        self.initial = initial
        self.sink = sink
        appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
    }

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 10, 10, 0, 0) { [weak self] _ in
                self?.snapshot()
            }
            reconcileTimer = timer
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            ready.signal()
            attach()
            snapshot()
            CFRunLoopRun()
        }
        thread.name = "hyprdarwin.ax.\(appName)"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    func stop() {
        perform { [self] in
            if let reconcileTimer { CFRunLoopTimerInvalidate(reconcileTimer) }
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            elements.removeAll()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func send(_ event: WorkerEvent) {
        DispatchQueue.main.async { [sink] in sink(event) }
    }

    // MARK: - Requests from the main thread

    func refresh() { perform { [self] in snapshot() } }

    func setHidden(_ isHidden: Bool) {
        perform { [self] in
            hidden = isHidden
            snapshot()
        }
    }

    /// Write frames. `positionOnly` entries keep their size (parking).
    /// `completion` runs on the worker thread once the batch is written.
    func setFrames(_ items: [(id: WindowID, frame: CGRect, positionOnly: Bool)], completion: (() -> Void)? = nil) {
        perform { [self] in
            defer { completion?() }
            // EnhancedUI makes apps animate and fight AX writes; switch it off
            // around the batch (yabai, AeroSpace and HyprMac do the same)
            let enhanced = boolAttribute(appElement, "AXEnhancedUserInterface") == true
            if enhanced { AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            var results: [WindowID: CGRect] = [:]
            for item in items {
                guard let element = elements[item.id] else { continue }
                if item.positionOnly {
                    setPosition(element, item.frame.origin)
                } else {
                    // size, move, size again: macOS clamps a resize to the
                    // screen the window is on, so the first one may be cut short
                    setSize(element, item.frame.size)
                    setPosition(element, item.frame.origin)
                    if let size = readSize(element), abs(size.width - item.frame.width) > 1 || abs(size.height - item.frame.height) > 1 {
                        setSize(element, item.frame.size)
                    }
                }
                if let frame = readFrame(element) { results[item.id] = frame }
            }
            if enhanced { AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
            send(.applied(results))
        }
    }

    /// Raise and focus `id` inside its app (the caller fronts the process).
    func raise(_ id: WindowID) {
        perform { [self] in
            guard let element = elements[id] else { return }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    func close(_ id: WindowID) {
        perform { [self] in
            guard let element = elements[id] else { return }
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
               let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    func reportFocus() { perform { [self] in sendFocus() } }

    // MARK: - Worker thread

    private func attach() {
        attachAttempts += 1
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else {
            retryAttach()
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var attached = false
        for name in Self.appNotifications {
            if AXObserverAddNotification(created, appElement, name as CFString, refcon) == .success { attached = true }
        }
        guard attached else {
            // a freshly launched app may not answer yet
            retryAttach()
            return
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        for (id, element) in elements { subscribe(element, id) }
    }

    private func retryAttach() {
        guard attachAttempts < 10 else {
            Log.info("AX observer for \(appName) (\(pid)) gave up; the 10 s reconcile still covers it")
            return
        }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0) { [weak self] _ in
            guard let self, self.observer == nil else { return }
            self.attach()
            self.snapshot()
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
    }

    private func subscribe(_ element: AXUIElement, _ id: WindowID) {
        guard let observer, !subscribed.contains(id) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let destroyed = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        for name in Self.windowNotifications.dropFirst() {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        // without the destroy notification the close would go unnoticed; retry next snapshot
        if destroyed == .success || destroyed == .notificationAlreadyRegistered { subscribed.insert(id) }
    }

    private func snapshot() {
        if hidden {
            send(.windows(pid: pid, [], initial: initial && !sentFirstSnapshot))
            sentFirstSnapshot = true
            return
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        let list: [AXUIElement]
        switch error {
        case .success:
            list = (value as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported:
            list = []
        default:
            // busy or not ready: a failed read must not look like "no windows"
            return
        }
        var infos: [WindowInfo] = []
        var present: Set<WindowID> = []
        for element in list {
            guard let id = windowID(of: element) else { continue }
            present.insert(id)
            AXUIElementSetMessagingTimeout(element, 1.0)
            elements[id] = element
            subscribe(element, id)
            if let info = readInfo(element, id: id) { infos.append(info) }
        }
        for id in elements.keys where !present.contains(id) {
            elements[id] = nil
            subscribed.remove(id)
        }
        send(.windows(pid: pid, infos, initial: initial && !sentFirstSnapshot))
        sentFirstSnapshot = true
    }

    private func readInfo(_ element: AXUIElement, id: WindowID) -> WindowInfo? {
        guard stringAttribute(element, kAXRoleAttribute) == kAXWindowRole as String else { return nil }
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        guard Self.admittedSubroles.contains(subrole) else { return nil }
        guard boolAttribute(element, kAXMinimizedAttribute) != true else { return nil }
        // native fullscreen windows live in their own Space; leave them alone
        guard boolAttribute(element, "AXFullScreen") != true else { return nil }
        guard let frame = readFrame(element), frame.width > 30, frame.height > 30 else { return nil }
        var settable = DarwinBoolean(false)
        let resizable = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success ? settable.boolValue : true
        return WindowInfo(
            id: id, pid: pid, bundleID: bundleID, appName: appName,
            title: stringAttribute(element, kAXTitleAttribute) ?? "",
            role: kAXWindowRole as String, subrole: subrole, frame: frame, isResizable: resizable
        )
    }

    private func sendFocus() {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            send(.focused(pid: pid, nil))
            return
        }
        send(.focused(pid: pid, windowID(of: value as! AXUIElement)))
    }

    fileprivate func handle(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            snapshot()
        case kAXUIElementDestroyedNotification:
            guard let id = elements.first(where: { CFEqual($0.value, element) })?.key else { return }
            elements[id] = nil
            subscribed.remove(id)
            send(.destroyed(pid: pid, id))
        case kAXMovedNotification, kAXResizedNotification:
            guard let id = elements.first(where: { CFEqual($0.value, element) })?.key,
                  let frame = readFrame(element) else { return }
            send(.frame(id, frame))
        case kAXTitleChangedNotification:
            guard let id = elements.first(where: { CFEqual($0.value, element) })?.key else { return }
            send(.title(id, stringAttribute(element, kAXTitleAttribute) ?? ""))
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            sendFocus()
        default:
            break
        }
    }

    // MARK: - AX helpers

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func readSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private func readFrame(_ element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point), let size = readSize(element) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }
}

// Runs on the worker's thread: the observer's source is on its run loop.
private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AppWorker>.fromOpaque(refcon).takeUnretainedValue().handle(notification as String, element)
}
