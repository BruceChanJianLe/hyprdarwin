import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinCore

private let screen = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                             visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))

private func info(_ id: WindowID, floating: Bool = false) -> WindowInfo {
    WindowInfo(id: id, pid: 100 + Int32(id), bundleID: "com.example.app", appName: "App", title: "Window",
               frame: CGRect(x: 100, y: 100, width: 400, height: 300), isResizable: !floating)
}

/// Tiles 1 and 2 and floating windows 3, 4 and 5 (unresizable windows
/// float) on workspace 1, opened silently in that order; tile 1 focused.
private func makeManager(_ configure: (inout Config) -> Void = { _ in }) -> WindowManager {
    var config = Config()
    config.gapsIn = Insets(all: 0)
    config.gapsOut = Insets(all: 0)
    configure(&config)
    let manager = WindowManager(config: config)
    manager.setMonitors([screen])
    for id: WindowID in [1, 2] { manager.addWindow(info(id), isNew: true) }
    for id: WindowID in [3, 4, 5] { manager.addWindow(info(id, floating: true), isNew: true) }
    manager.externalFocus(1)
    return manager
}

@Suite struct FloatingOnTopTests {
    @Test func isOnByDefault() {
        #expect(Config().floatingOnTop)
    }

    @Test func focusingATileRaisesTheFloatingWindowsMostRecentlyFocusedLast() {
        let manager = makeManager()
        // 5 was focused before 3; 4 never was
        _ = manager.dispatch(.cycleWindows(.floating, reverse: true))
        #expect(manager.focusedWindow == 5)
        manager.externalFocus(3)
        manager.externalFocus(1)
        let effects = manager.dispatch(.focusDirection(.right))
        #expect(manager.focusedWindow == 2)
        #expect(effects.first == .focus(2))
        #expect(effects.contains(.raiseFloating(over: 2, [4, 5, 3])))
        // the keyboard stays on the tile: nothing focuses a floating window
        #expect(!effects.contains { if case .focus(let id) = $0 { id != 2 } else { false } })
        #expect(!effects.contains { if case .activate = $0 { true } else { false } })
    }

    @Test func clickingATileRaisesThemWithoutTouchingTheKeyboard() {
        let manager = makeManager()
        #expect(manager.externalFocus(2) == [.raiseFloating(over: 2, [3, 4, 5])])
        #expect(manager.focusedWindow == 2)
        #expect(manager.focusFromCursor(1) == [.focus(1), .raiseFloating(over: 1, [3, 4, 5])])
    }

    @Test func focusingAFloatingWindowRaisesNothingElse() {
        let manager = makeManager()
        #expect(manager.externalFocus(4).isEmpty)
        #expect(manager.raiseFloating(over: 4).isEmpty)
        let effects = manager.dispatch(.cycleWindows(.floating, reverse: false))
        #expect(effects.first == .focus(5))
        #expect(!effects.contains { if case .raiseFloating = $0 { true } else { false } })
    }

    @Test func theOptionTurnsItOff() {
        let manager = makeManager { $0.floatingOnTop = false }
        #expect(manager.externalFocus(2).isEmpty)
        #expect(manager.raiseFloating(over: 1).isEmpty)
    }

    @Test func onlyTheTilesOwnWorkspaceOnScreen() {
        let manager = makeManager()
        // 5 goes to workspace 2, which stays hidden
        manager.externalFocus(5)
        _ = manager.dispatch(.moveToWorkspace(.id(.numbered(2)), follow: false))
        manager.externalFocus(1)
        #expect(manager.raiseFloating(over: 1) == [.raiseFloating(over: 1, [3, 4])])
        // a floating window on another Space (or in native fullscreen) is not on screen
        manager.applyListing([info(1), info(2), info(3, floating: true)], away: [4], previous: [1, 2, 3, 4], initial: false)
        #expect(manager.windows[4]?.isAway == true)
        #expect(manager.raiseFloating(over: 1) == [.raiseFloating(over: 1, [3])])
        // nothing for a tile on a hidden workspace
        manager.addWindow(info(6), isNew: false)
        _ = manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        #expect(manager.raiseFloating(over: 1).isEmpty)
    }

    @Test func aFullscreenWindowStaysAboveEverything() {
        let manager = makeManager()
        #expect(manager.dispatch(.fullscreen(.fullscreen, .set)) == [.focus(1)])
        #expect(manager.raiseFloating(over: 2).isEmpty)
        #expect(manager.focusedFullscreen == .fullscreen)
        // ending it puts the floating windows back over the tile
        #expect(manager.dispatch(.fullscreen(.fullscreen, .unset)) == [.focus(1), .raiseFloating(over: 1, [3, 4, 5])])
        #expect(manager.focusedFullscreen == nil)
        _ = manager.dispatch(.fullscreen(.maximized, .set))
        #expect(manager.focusedFullscreen == .maximized)
        manager.externalFocus(3)
        #expect(manager.focusedFullscreen == nil, "focus left the maximized window, which steps back")
    }

    @Test func anOpenSpecialWorkspaceStaysAboveTheOneBelow() {
        let manager = makeManager()
        _ = manager.dispatch(.toggleSpecial("scratch"))
        #expect(manager.raiseFloating(over: 1).isEmpty)
        manager.addWindow(info(7), isNew: true)
        manager.addWindow(info(8, floating: true), isNew: true)
        #expect(manager.windows[7]?.workspace == .special("scratch"))
        #expect(manager.raiseFloating(over: 7) == [.raiseFloating(over: 7, [8])])
    }

    @Test func tilesTooBigToTileCountAsFloating() {
        let manager = makeManager()
        manager.addWindow(info(6), isNew: false)
        _ = manager.windowRefusedSize(6, minimum: CGSize(width: 900, height: 0))
        #expect(manager.computePlan().overflow == [6])
        #expect(manager.raiseFloating(over: 1) == [.raiseFloating(over: 1, [3, 4, 5, 6])])
        #expect(manager.raiseFloating(over: 6).isEmpty)
    }

    @Test func bringToTop() {
        let manager = makeManager()
        #expect(manager.dispatch(.bringToTop) == [.focus(1), .raiseFloating(over: 1, [3, 4, 5])])
        manager.externalFocus(4)
        #expect(manager.dispatch(.bringToTop) == [.focus(4)])
    }

    @Test func focusLastRaisesOnce() {
        let manager = makeManager()
        manager.externalFocus(2)
        let effects = manager.dispatch(.focusLast)
        #expect(manager.focusedWindow == 1)
        #expect(effects.filter { if case .raiseFloating = $0 { true } else { false } } == [.raiseFloating(over: 1, [3, 4, 5])])
    }

    @Test func theRaisesEchoDoesNotPingPong() {
        let manager = makeManager()
        var tracker = FocusTracker()
        let t0 = Date()
        let effects = manager.externalFocus(2)
        guard case let .raiseFloating(over, floating)? = effects.first else {
            Issue.record("expected a raise")
            return
        }
        tracker.raising(floating, now: t0)
        // the app keys a window it raised, then the tile again: neither moves focus or raises again
        #expect(tracker.isRaiseEcho(3, now: t0.addingTimeInterval(0.05)))
        #expect(!tracker.isRaiseEcho(over, now: t0.addingTimeInterval(0.05)))
        let step = tracker.osFocus(over, pid: 102, model: manager, now: t0.addingTimeInterval(0.06))
        #expect(step.effects.isEmpty && step.recheckAfter == nil)
        #expect(manager.focusedWindow == 2)
        // after the grace a focus on it is the user's
        #expect(!tracker.isRaiseEcho(3, now: t0.addingTimeInterval(FocusTracker.raiseEchoGrace)))
        #expect(tracker.osFocus(3, pid: 103, model: manager, now: t0.addingTimeInterval(1.5)).effects.isEmpty)
        #expect(manager.focusedWindow == 3, "a floating window taking focus raises nothing")
        tracker.raising([4, 5], now: t0.addingTimeInterval(2))
        tracker.forget(4)
        #expect(!tracker.isRaiseEcho(4, now: t0.addingTimeInterval(2.1)))
        #expect(tracker.isRaiseEcho(5, now: t0.addingTimeInterval(2.1)))
    }
}
