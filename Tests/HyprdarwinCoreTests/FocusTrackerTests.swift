import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinCore

private let screen = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                             visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
private let ghostty: Int32 = 900
private let textEdit: Int32 = 500

private func window(_ id: WindowID, pid: Int32, title: String) -> WindowInfo {
    WindowInfo(id: id, pid: pid, bundleID: pid == textEdit ? "com.apple.TextEdit" : "com.example.app", appName: "App",
               title: title, subrole: "AXStandardWindow", frame: CGRect(x: 100, y: 100, width: 400, height: 300),
               isResizable: true)
}

/// misc.focus_on_open off, TextEdit opens on "6 silent", Ghostty (unmanaged) has the keyboard.
private func makeManager() throws -> WindowManager {
    var config = Config()
    config.focusOnOpen = false
    var match = WindowRuleMatch()
    match.initialClass = try RulePattern("TextEdit")
    var effects = WindowRuleEffects()
    effects.workspace = WorkspaceTarget(parsing: "6 silent")
    config.windowRules = [WindowRule(match: match, effects: effects)]
    let manager = WindowManager(config: config)
    manager.setMonitors([screen])
    manager.addWindow(window(1, pid: 101, title: "Safari"), isNew: false)
    manager.externalFocus(1)
    return manager
}

@Suite struct FocusTrackerTests {
    @Test func newWindowKeyedBeforeItIsAddedGivesTheKeyboardBack() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        tracker.noteKeyboard(pid: ghostty, window: 50, model: model)
        // TextEdit launches and macOS keys its new window before the snapshot has it
        tracker.noteKeyboard(pid: textEdit, window: nil, model: model)
        tracker.noteKeyboard(pid: textEdit, window: 10, model: model)
        let step = tracker.osFocus(10, pid: textEdit, model: model, now: t0)
        #expect(step.effects.isEmpty && step.recheckAfter == nil)

        model.addWindow(window(10, pid: textEdit, title: "Untitled"), isNew: true)
        #expect(tracker.opened(10, model: model, now: t0.addingTimeInterval(0.2)) == [.activate(pid: ghostty, window: 50)],
                "Ghostty gets the keyboard back once the window lands hidden")
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(model.focusedWindow == 1)
    }

    @Test func newWindowOfAFrontmostAppWithNoFocusEventIsCheckedAndGivesTheKeyboardBack() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        tracker.noteKeyboard(pid: ghostty, window: 50, model: model)
        // TextEdit launches: it activates with no window yet, and its first
        // window is keyed before the AX observer exists, so no focus event comes
        tracker.noteKeyboard(pid: textEdit, window: nil, model: model)
        model.addWindow(window(10, pid: textEdit, title: "Untitled"), isNew: true)
        #expect(tracker.opened(10, model: model, now: t0).isEmpty)

        // the caller asks the frontmost app for its focused window
        tracker.noteKeyboard(pid: textEdit, window: 10, model: model)
        let step = tracker.osFocus(10, pid: textEdit, model: model, now: t0.addingTimeInterval(0.3))
        #expect(step.effects == [.activate(pid: ghostty, window: 50)] && step.recheckAfter == nil)
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(model.focusedWindow == 1)
    }

    /// HYPR+Enter opens a terminal window on the visible workspace and macOS
    /// keys it with no focus event: the check makes it the focused window,
    /// so the highlight follows and the next window splits from it.
    @Test func newWindowOnTheVisibleWorkspaceTakesFocusWithTheKeyboard() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        tracker.noteKeyboard(pid: 101, window: 1, model: model)
        model.addWindow(window(2, pid: 101, title: "Safari 2"), isNew: true)
        #expect(tracker.opened(2, model: model, now: t0).isEmpty)
        #expect(model.focusedWindow == 1)

        tracker.noteKeyboard(pid: 101, window: 2, model: model)
        let step = tracker.osFocus(2, pid: 101, model: model, now: t0.addingTimeInterval(0.3))
        #expect(step.effects.isEmpty && step.recheckAfter == nil)
        #expect(model.focusedWindow == 2)
        #expect(model.workspaces[.numbered(1)]?.lastFocused == 2)
    }

    /// Brave keys a new window long before it lists it: the stale focus
    /// event no longer counts, and the check after the late open does.
    @Test func lateListedNewWindowTakesFocusWithTheKeyboard() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        tracker.noteKeyboard(pid: 101, window: 2, model: model)
        #expect(tracker.osFocus(2, pid: 101, model: model, now: t0).effects.isEmpty)
        model.addWindow(window(2, pid: 101, title: "late"), isNew: true)
        let late = t0.addingTimeInterval(FocusTracker.openGrace + 1)
        #expect(tracker.opened(2, model: model, now: late).isEmpty)
        #expect(model.focusedWindow == 1)

        _ = tracker.osFocus(2, pid: 101, model: model, now: late.addingTimeInterval(0.1))
        #expect(model.focusedWindow == 2)
    }

    @Test func newWindowOpenedInTheBackgroundLeavesFocusAlone() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        tracker.noteKeyboard(pid: 101, window: 1, model: model)
        model.addWindow(window(3, pid: 101, title: "background"), isNew: true)
        #expect(tracker.opened(3, model: model, now: t0).isEmpty)
        // the check finds the keyboard still on window 1
        #expect(tracker.osFocus(1, pid: 101, model: model, now: t0.addingTimeInterval(0.1)).effects.isEmpty)
        #expect(model.focusedWindow == 1)
    }

    @Test func activatingAnAppWithAHiddenWindowThenOpeningAnotherStaysPut() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        model.addWindow(window(10, pid: textEdit, title: "first"), isNew: true)
        _ = tracker.opened(10, model: model, now: t0)
        tracker.noteKeyboard(pid: ghostty, window: 50, model: model)

        // `open -a TextEdit file2` 3 s later: macOS first keys the existing parked window
        let t1 = t0.addingTimeInterval(3)
        tracker.noteKeyboard(pid: textEdit, window: nil, model: model)
        tracker.noteKeyboard(pid: textEdit, window: 10, model: model)
        let step = tracker.osFocus(10, pid: textEdit, model: model, now: t1)
        #expect(step.effects.isEmpty, "the switch to workspace 6 waits")
        #expect(step.recheckAfter == FocusTracker.switchDelay)
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))

        // then the new window opens hidden and is keyed too
        model.addWindow(window(11, pid: textEdit, title: "file2"), isNew: true)
        #expect(tracker.opened(11, model: model, now: t1.addingTimeInterval(0.1)) == [.activate(pid: ghostty, window: 50)])
        tracker.noteKeyboard(pid: textEdit, window: 11, model: model)
        #expect(tracker.previousKeyboardOwner == KeyboardOwner(pid: ghostty, window: 50),
                "a parked window is never the one to hand back to")
        #expect(tracker.osFocus(11, pid: textEdit, model: model, now: t1.addingTimeInterval(0.2)).effects
                    == [.activate(pid: ghostty, window: 50)])
        #expect(tracker.switchDue(model: model, keyboardOn: 10, now: t1.addingTimeInterval(0.5)).isEmpty, "switch cancelled")
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(model.focusedWindow == 1)
    }

    @Test func focusingAHiddenWindowStillSwitchesAfterTheDelay() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        model.addWindow(window(10, pid: textEdit, title: "first"), isNew: true)
        _ = tracker.opened(10, model: model, now: t0)

        // a plain Cmd-Tab to TextEdit later on
        let t1 = t0.addingTimeInterval(5)
        tracker.noteKeyboard(pid: textEdit, window: 10, model: model)
        #expect(tracker.osFocus(10, pid: textEdit, model: model, now: t1).recheckAfter == FocusTracker.switchDelay)
        #expect(tracker.switchDue(model: model, keyboardOn: 10, now: t1.addingTimeInterval(0.1)).isEmpty, "not yet")
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))
        _ = tracker.switchDue(model: model, keyboardOn: 10, now: t1.addingTimeInterval(FocusTracker.switchDelay))
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(6))
        #expect(model.focusedWindow == 10)
    }

    @Test func aSwitchIsDroppedWhenTheKeyboardMovedOn() throws {
        let model = try makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        model.addWindow(window(10, pid: textEdit, title: "first"), isNew: true)
        _ = tracker.opened(10, model: model, now: t0)
        let t1 = t0.addingTimeInterval(5)
        _ = tracker.osFocus(10, pid: textEdit, model: model, now: t1)
        #expect(tracker.switchDue(model: model, keyboardOn: 50, now: t1.addingTimeInterval(1)).isEmpty)
        #expect(model.monitorStates[1]?.activeWorkspace == .numbered(1))
    }
}
