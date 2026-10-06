import Foundation

/// Turns OS keyboard focus changes into model focus, telling "macOS keyed a
/// window an app just opened" apart from the user focusing a window. With
/// misc.focus_on_open off, a new window on a hidden workspace hands the
/// keyboard back to whoever had it, however macOS orders the events:
///
/// - the new window can be keyed before a snapshot adds it to the model, so
///   a focus on an unknown window is remembered until it is added;
/// - an app that already has a window on a hidden workspace keys that one
///   first, so switching to a hidden window waits `switchDelay`, and a new
///   window of the same app opening hidden meanwhile cancels the switch.
public struct FocusTracker {
    /// How long after opening a window macOS keying it counts as the open.
    public static let openGrace: TimeInterval = 2
    /// How long a switch to a hidden window's workspace waits for a new
    /// window of the same app.
    public static let switchDelay: TimeInterval = 0.4

    struct Pending {
        var id: WindowID
        var pid: Int32
        var previousOwner: KeyboardOwner?
        var at: Date
    }

    /// Who has the keyboard now and who had it before (any app, managed or
    /// not). A window on a hidden workspace is never one to hand back to.
    public private(set) var keyboardOwner: KeyboardOwner?
    public private(set) var previousKeyboardOwner: KeyboardOwner?
    private var openedAt: [WindowID: Date] = [:]
    private var unknownFocus: Pending?
    private var deferredSwitch: Pending?

    public init() {}

    /// Track the keyboard's owner: a new frontmost app, or a new focused
    /// window within it (an app reporting no window keeps the one it had).
    public mutating func noteKeyboard(pid: Int32, window: WindowID?, model: WindowManager) {
        let current = keyboardOwner
        let returnable = current.map { owner in
            owner.window.flatMap { model.windows[$0] }.map { model.isVisible($0.workspace) } ?? true
        } ?? false
        if pid != current?.pid {
            if returnable { previousKeyboardOwner = current }
            keyboardOwner = KeyboardOwner(pid: pid, window: window)
        } else if let window, window != current?.window {
            if current?.window != nil, returnable { previousKeyboardOwner = current }
            keyboardOwner?.window = window
        }
    }

    /// The OS keyed window `id` of app `pid`. Returns the effects to perform
    /// now and, for a deferred workspace switch, when to call `switchDue`.
    public mutating func osFocus(_ id: WindowID, pid: Int32, model: WindowManager,
                                 now: Date = Date()) -> (effects: [Effect], recheckAfter: TimeInterval?) {
        deferredSwitch = nil
        guard let window = model.windows[id] else {
            unknownFocus = Pending(id: id, pid: pid, previousOwner: previousKeyboardOwner, at: now)
            return ([], nil)
        }
        guard id != model.focusedWindow else { return ([], nil) }
        let justOpened = openedAt[id].map { now.timeIntervalSince($0) < Self.openGrace } ?? false
        if !justOpened, !model.config.focusOnOpen, !model.isVisible(window.workspace) {
            deferredSwitch = Pending(id: id, pid: pid, previousOwner: previousKeyboardOwner, at: now)
            return ([], Self.switchDelay)
        }
        return (model.externalFocus(id, justOpened: justOpened, previousOwner: previousKeyboardOwner), nil)
    }

    /// A new window was added to the model.
    public mutating func opened(_ id: WindowID, model: WindowManager, now: Date = Date()) -> [Effect] {
        openedAt[id] = now
        guard let window = model.windows[id], id != model.focusedWindow else { return [] }
        if let pending = unknownFocus, pending.id == id {
            unknownFocus = nil
            deferredSwitch = nil
            guard now.timeIntervalSince(pending.at) < Self.openGrace else { return [] }
            return model.externalFocus(id, justOpened: true, previousOwner: pending.previousOwner)
        }
        if let pending = deferredSwitch, pending.pid == window.info.pid,
           now.timeIntervalSince(pending.at) < Self.switchDelay,
           !model.config.focusOnOpen, !model.isVisible(window.workspace) {
            deferredSwitch = nil
            return model.externalFocus(id, justOpened: true, previousOwner: pending.previousOwner)
        }
        return []
    }

    /// The window is gone (or became another tab window).
    public mutating func forget(_ id: WindowID) {
        openedAt[id] = nil
        if unknownFocus?.id == id { unknownFocus = nil }
        if deferredSwitch?.id == id { deferredSwitch = nil }
    }

    /// `switchDelay` after a deferred switch: bring the hidden window's
    /// workspace into view if the keyboard (`keyboardOn`) is still there.
    public mutating func switchDue(model: WindowManager, keyboardOn: WindowID?, now: Date = Date()) -> [Effect] {
        guard let pending = deferredSwitch, now.timeIntervalSince(pending.at) >= Self.switchDelay * 0.9 else { return [] }
        deferredSwitch = nil
        guard pending.id == keyboardOn, model.windows[pending.id] != nil, pending.id != model.focusedWindow else { return [] }
        return model.externalFocus(pending.id)
    }
}
