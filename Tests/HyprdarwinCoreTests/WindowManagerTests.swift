import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinCore

/// Primary 1000x800 display (menu bar 0-25) and a second one to its right.
private let primary = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
private let external = Monitor(id: 2, name: "DELL U3423WE", frame: CGRect(x: 1000, y: 0, width: 1200, height: 800),
                               visibleFrame: CGRect(x: 1000, y: 0, width: 1200, height: 800))

private func info(_ id: WindowID, bundle: String = "com.example.app", title: String = "Window",
                  frame: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300),
                  subrole: String = "AXStandardWindow", resizable: Bool = true) -> WindowInfo {
    WindowInfo(id: id, pid: 100 + Int32(id), bundleID: bundle, appName: "App", title: title,
               subrole: subrole, frame: frame, isResizable: resizable)
}

private func makeManager(_ configure: (inout Config) -> Void = { _ in }, monitors: [Monitor] = [primary]) -> WindowManager {
    var config = Config()
    // most scenarios here are about focus moving with new windows
    config.focusOnOpen = true
    config.gapsIn = Insets(all: 0)
    config.gapsOut = Insets(all: 0)
    configure(&config)
    let manager = WindowManager(config: config)
    manager.setMonitors(monitors)
    return manager
}

private func rule(_ build: (inout WindowRuleMatch, inout WindowRuleEffects) throws -> Void) rethrows -> WindowRule {
    var match = WindowRuleMatch()
    var effects = WindowRuleEffects()
    try build(&match, &effects)
    return WindowRule(match: match, effects: effects)
}

@Suite struct WindowManagerTests {
    @Test func monitorsStartOnWorkspacesOneAndTwo() {
        let manager = makeManager(monitors: [primary, external])
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(manager.monitorStates[2]?.activeWorkspace == .numbered(2))
        #expect(manager.focusedWorkspaceID == .numbered(1))
    }

    @Test func defaultWorkspaceRuleBindsAMonitor() {
        let manager = makeManager({ config in
            var r = WorkspaceRule(workspace: .numbered(5))
            r.monitor = "DELL"
            r.isDefault = true
            config.workspaceRules = [r]
        }, monitors: [primary, external])
        #expect(manager.monitorStates[2]?.activeWorkspace == .numbered(5))
    }

    @Test func newWindowsTileAndTakeFocus() {
        let manager = makeManager()
        #expect(manager.addWindow(info(1), isNew: true) == [.focus(1)])
        manager.addWindow(info(2), isNew: true)
        let plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 500, height: 775))
        #expect(plan.frame(of: 2) == CGRect(x: 500, y: 25, width: 500, height: 775))
        #expect(manager.focusedWindow == 2)
        let events = manager.drainEvents()
        #expect(events.contains(.openWindow(1, workspace: .numbered(1), bundleID: "com.example.app", title: "Window")))
        #expect(events.contains(.activeWindow(2, bundleID: "com.example.app", title: "Window")))
    }

    @Test func gapsInAndOut() {
        let manager = makeManager { config in
            config.gapsIn = Insets(all: 5)
            config.gapsOut = Insets(all: 10)
        }
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        let plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 10, y: 35, width: 485, height: 755))
        #expect(plan.frame(of: 2) == CGRect(x: 505, y: 35, width: 485, height: 755))
    }

    @Test func adoptedWindowsDoNotStealFocus() {
        let manager = makeManager(monitors: [primary, external])
        #expect(manager.addWindow(info(1, frame: CGRect(x: 1200, y: 100, width: 400, height: 300)), isNew: false).isEmpty)
        #expect(manager.windows[1]?.workspace == .numbered(2))
        #expect(manager.focusedWindow == nil)
    }

    @Test func unresizableWindowsFloat() {
        let manager = makeManager()
        manager.addWindow(info(1, resizable: false), isNew: true)
        #expect(manager.windows[1]?.isFloating == true)
        #expect(manager.computePlan().frame(of: 1) == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func switchingWorkspacesParksHiddenWindows() {
        let manager = makeManager(monitors: [primary, external])
        manager.addWindow(info(1), isNew: true)
        let effects = manager.dispatch(.focusWorkspace(.id(.numbered(3)), onCurrentMonitor: false))
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(3))
        #expect(manager.focusedWindow == nil)
        #expect(effects.isEmpty)
        // parked one point inside the bottom-right corner of the right-most monitor
        #expect(manager.computePlan().placements[1] == .hidden(CGPoint(x: 2199, y: 799)))
        #expect(manager.workspaces[.numbered(1)] != nil)

        manager.dispatch(.focusWorkspace(.id(.numbered(1)), onCurrentMonitor: false))
        #expect(manager.focusedWindow == 1)
        #expect(manager.workspaces[.numbered(3)] == nil, "empty hidden workspaces are destroyed")
        #expect(manager.resolve(workspace: .previous) == .numbered(3))
    }

    @Test func workspacesBeyondTenAndExistingRelative() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.dispatch(.focusWorkspace(.id(.numbered(15)), onCurrentMonitor: false))
        manager.addWindow(info(2), isNew: true)
        #expect(manager.windows[2]?.workspace == .numbered(15))
        #expect(manager.resolve(workspace: .existing(1)) == .numbered(1))
        #expect(manager.resolve(workspace: .existing(-1)) == .numbered(1))
        #expect(manager.resolve(workspace: .relative(1)) == .numbered(16))
        #expect(manager.resolve(workspace: .empty) == .numbered(2))
    }

    @Test func relativeOnMonitorIncludesEmptyWorkspacesAndSkipsOtherMonitors() {
        let manager = makeManager(monitors: [primary, external])
        // workspace 2 is shown on the external monitor; 1 is focused here
        #expect(manager.resolve(workspace: .relativeOnMonitor(1)) == .numbered(3), "2 lives on the other monitor")
        #expect(manager.resolve(workspace: .relativeOnMonitor(2)) == .numbered(4))
        #expect(manager.resolve(workspace: .relativeOnMonitor(-1)) == .numbered(1), "never below 1")
        manager.dispatch(.focusWorkspace(.relativeOnMonitor(1), onCurrentMonitor: false))
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(3))
        #expect(manager.resolve(workspace: .relativeOnMonitor(-1)) == .numbered(1))
        // e+1 only visits workspaces that exist: 3 is empty but shown, so 1 is gone
        #expect(manager.resolve(workspace: .existing(1)) == .numbered(2))
    }

    @Test func retileReappliesRulesAndRebuildsLayouts() throws {
        let rules = try [
            rule { match, effects in
                match.class = try RulePattern("^com\\.example\\.float$")
                effects.float = true
                effects.center = true
            },
            rule { match, effects in
                match.class = try RulePattern("^com\\.example\\.chat$")
                effects.workspace = WorkspaceTarget(workspace: .numbered(3), silent: true)
            },
        ]
        let manager = makeManager { config in
            config.focusOnOpen = false
            config.windowRules = rules
        }
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.addWindow(info(3, bundle: "com.example.float", frame: CGRect(x: 0, y: 25, width: 200, height: 100)), isNew: true)
        manager.addWindow(info(4, bundle: "com.example.chat"), isNew: true)
        #expect(manager.windows[4]?.workspace == .numbered(3))
        // the user tiles the floating window, moves the chat window here and resizes a split
        manager.markFocused(3)
        manager.dispatch(.float(.unset))
        manager.markFocused(1)
        manager.dispatch(.resize(x: 200, y: 0, relative: true))
        manager.windows[4]?.workspace = .numbered(1)
        manager.workspaces[.numbered(3)]?.layout.remove(4)
        let area = try #require(manager.tilingArea(for: .numbered(1)))
        manager.workspaces[.numbered(1)]?.layout.insert(4, focused: 1, area: area, options: manager.config.layoutOptions, cursor: nil)
        manager.windows[3]?.floatingFrame = CGRect(x: 600, y: 600, width: 200, height: 100)

        let effects = manager.dispatch(.retile)
        #expect(effects.last == .rewriteAll)
        #expect(manager.windows[3]?.isFloating == true, "float rule applies again")
        #expect(manager.windows[3]?.floatingFrame == CGRect(x: 400, y: 363, width: 200, height: 100), "centred again")
        #expect(manager.windows[4]?.workspace == .numbered(3), "workspace rule applies again, silently")
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))
        // the remaining tiles are split evenly again, in their order
        let plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 500, height: 775))
        #expect(plan.frame(of: 2) == CGRect(x: 500, y: 25, width: 500, height: 775))
    }

    @Test func retileKeepsWindowsNoRuleDecides() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.float(.set))
        manager.addWindow(info(3, resizable: false), isNew: true)
        manager.dispatch(.retile)
        #expect(manager.windows[1]?.isFloating == false)
        #expect(manager.windows[2]?.isFloating == true, "floated by hand, no rule says otherwise")
        #expect(manager.windows[3]?.isFloating == true, "not resizable: always floats")
        #expect(manager.workspaces[.numbered(1)]?.layout.windows == [1])
    }

    @Test func focusingAWorkspaceOnAnotherMonitorFocusesThatMonitor() {
        let manager = makeManager(monitors: [primary, external])
        manager.addWindow(info(1, frame: CGRect(x: 1200, y: 100, width: 400, height: 300)), isNew: false)
        let effects = manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        #expect(manager.focusedMonitorID == 2)
        #expect(manager.focusedWindow == 1)
        #expect(effects.first == .focus(1))
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))
    }

    @Test func moveToWorkspaceFollowAndSilent() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.moveToWorkspace(.id(.numbered(4)), follow: false))
        #expect(manager.windows[2]?.workspace == .numbered(4))
        #expect(manager.focusedWindow == 1)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(manager.computePlan().frame(of: 1) == primary.visibleFrame)

        manager.dispatch(.moveToWorkspace(.id(.numbered(4)), follow: true))
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(4))
        #expect(manager.focusedWindow == 1)
        #expect(manager.workspaces[.numbered(1)] == nil)
    }

    @Test func windowRulesPlaceAndFloat() throws {
        let manager = makeManager { config in
            config.windowRules = [
                try! rule { match, effects in
                    match.class = try RulePattern("^com\\.tinyspeck\\.slackmacgap$")
                    effects.workspace = WorkspaceTarget(parsing: "3 silent")
                },
                try! rule { match, effects in
                    match.class = try RulePattern("calculator")
                    effects.float = true
                    effects.size = "200 100"
                    effects.center = true
                },
            ]
        }
        manager.addWindow(info(1), isNew: true)
        #expect(manager.addWindow(info(2, bundle: "com.tinyspeck.slackmacgap"), isNew: true).isEmpty)
        #expect(manager.windows[2]?.workspace == .numbered(3))
        #expect(manager.focusedWindow == 1)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))

        manager.addWindow(info(3, bundle: "com.apple.calculator"), isNew: true)
        #expect(manager.windows[3]?.isFloating == true)
        #expect(manager.computePlan().frame(of: 3) == CGRect(x: 400, y: 363, width: 200, height: 100))
        #expect(manager.computePlan().frame(of: 1) == primary.visibleFrame)
    }

    @Test func nonSilentWorkspaceRuleSwitchesToTheWindow() throws {
        let manager = makeManager { config in
            config.windowRules = [try! rule { match, effects in
                match.title = try RulePattern("^Mail")
                effects.workspace = WorkspaceTarget(parsing: "6")
            }]
        }
        manager.addWindow(info(1, title: "Mail - Inbox"), isNew: true)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(6))
        #expect(manager.focusedWindow == 1)
    }

    @Test func negativeAndLastWinsRules() throws {
        let manager = makeManager { config in
            config.windowRules = [
                try! rule { match, effects in
                    match.class = try RulePattern(".*")
                    effects.float = true
                },
                try! rule { match, effects in
                    match.title = try RulePattern("negative:Meeting")
                    effects.float = false
                },
            ]
        }
        manager.addWindow(info(1, title: "Chat"), isNew: true)
        manager.addWindow(info(2, title: "Meeting with X"), isNew: true)
        #expect(manager.windows[1]?.isFloating == false)
        #expect(manager.windows[2]?.isFloating == true)
    }

    @Test func specialWorkspaceToggles() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.moveToWorkspace(.id(.special("scratch")), follow: false))
        #expect(manager.computePlan().placements[2] == .hidden(CGPoint(x: 999, y: 799)))
        #expect(manager.focusedWindow == 1)

        manager.dispatch(.toggleSpecial("scratch"))
        #expect(manager.monitorStates[1]?.special == "scratch")
        #expect(manager.focusedWindow == 2)
        #expect(manager.computePlan().frame(of: 2) == primary.visibleFrame)
        #expect(manager.computePlan().frame(of: 1) == primary.visibleFrame, "the regular workspace stays underneath")

        manager.addWindow(info(3), isNew: true)
        #expect(manager.windows[3]?.workspace == .special("scratch"))

        manager.dispatch(.toggleSpecial("scratch"))
        #expect(manager.monitorStates[1]?.special == nil)
        #expect(manager.focusedWindow == 1)
        #expect(manager.workspaces[.special("scratch")] != nil)
    }

    @Test func externalFocusRevealsHiddenWorkspace() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        manager.externalFocus(1)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))
        #expect(manager.focusedWindow == 1)
    }

    @Test func closingTheFocusedWindowFocusesTheNextOne() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.addWindow(info(3), isNew: true)
        manager.externalFocus(1)
        manager.externalFocus(3)
        #expect(manager.removeWindow(3) == [.focus(1)])
        #expect(manager.computePlan().frame(of: 1)?.width == 500)
    }

    @Test func directionalFocusSwapAndMove() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.cursor = CGPoint(x: 750, y: 400)
        #expect(manager.dispatch(.focusDirection(.left)) == [.focus(1), .warpCursor(CGPoint(x: 250, y: 412.5))])
        manager.dispatch(.swapDirection(.right))
        #expect(manager.computePlan().frame(of: 1)?.minX == 500)
        manager.dispatch(.moveDirection(.left))
        #expect(manager.computePlan().frame(of: 1)?.minX == 0)
    }

    @Test func moveDirectionHopsMonitors() {
        let manager = makeManager(monitors: [primary, external])
        manager.addWindow(info(1), isNew: true)
        manager.dispatch(.moveDirection(.right))
        #expect(manager.windows[1]?.workspace == .numbered(2))
        #expect(manager.focusedMonitorID == 2)
        #expect(manager.computePlan().frame(of: 1) == external.visibleFrame)
    }

    @Test func floatToggleAndResize() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.float(.toggle))
        #expect(manager.windows[2]?.isFloating == true)
        #expect(manager.computePlan().frame(of: 1) == primary.visibleFrame)
        manager.dispatch(.resize(x: 100, y: 50, relative: true))
        #expect(manager.computePlan().frame(of: 2)?.size == CGSize(width: 500, height: 350))
        manager.dispatch(.float(.unset))
        #expect(manager.computePlan().frame(of: 2)?.width == 500)

        manager.dispatch(.resize(x: 100, y: 0, relative: true))
        #expect(manager.computePlan().frame(of: 2)?.width == 600)
        manager.dispatch(.resize(x: 300, y: 775, relative: false))
        #expect(manager.computePlan().frame(of: 2)?.width == 300)
    }

    @Test func fullscreenModes() {
        let manager = makeManager { $0.gapsOut = Insets(all: 10) }
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.fullscreen(.fullscreen, .toggle))
        #expect(manager.computePlan().frame(of: 2) == primary.visibleFrame)
        manager.dispatch(.fullscreen(.maximized, .toggle))
        #expect(manager.computePlan().frame(of: 2) == primary.visibleFrame.inset(by: Insets(all: 10)))
        manager.dispatch(.fullscreen(.maximized, .toggle))
        #expect(manager.computePlan().frame(of: 2)?.width == 490)
    }

    @Test func fullscreenParksTheRestOfItsWorkspace() {
        let manager = makeManager { $0.gapsOut = Insets(all: 10) }
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.addWindow(info(3, resizable: false), isNew: true)
        manager.externalFocus(2)
        manager.dispatch(.fullscreen(.maximized, .set))
        var plan = manager.computePlan()
        #expect(plan.frame(of: 2) == primary.visibleFrame.inset(by: Insets(all: 10)))
        #expect(plan.placements[1] == .hidden(CGPoint(x: 999, y: 799)))
        #expect(plan.placements[3] == .hidden(CGPoint(x: 999, y: 799)), "floating windows too")

        // focusing a hidden sibling (Cmd-Tab) leaves fullscreen
        manager.externalFocus(1)
        plan = manager.computePlan()
        #expect(manager.windows[2]?.fullscreen == nil)
        #expect(plan.frame(of: 1)?.width == 490)

        // so does a new window opening on that workspace
        manager.dispatch(.fullscreen(.fullscreen, .set))
        manager.addWindow(info(4), isNew: true)
        #expect(manager.windows[1]?.fullscreen == nil)
        #expect(manager.computePlan().frame(of: 4) != nil)
    }

    @Test func perWorkspaceLayoutAndConfigReload() {
        let manager = makeManager { config in
            var r = WorkspaceRule(workspace: .numbered(2))
            r.layout = .master
            config.workspaceRules = [r]
        }
        manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        for id: WindowID in 1...3 { manager.addWindow(info(id), isNew: true) }
        #expect(manager.workspaces[.numbered(2)]?.layout.isKind(.master) == true)
        #expect(manager.workspaces[.numbered(2)]?.layout.kind == .mainVertical, "master.orientation left")
        #expect(manager.computePlan().frame(of: 1)?.width == 550)

        var config = manager.config
        config.workspaceRules = []
        config.layoutOptions.master.mfact = 0.7
        manager.setConfig(config)
        #expect(manager.workspaces[.numbered(2)]?.layout.kind == .dwindle)
        #expect(manager.drainEvents().last == .configReloaded)
    }

    @Test func submapsAndLayoutMessages() {
        let manager = makeManager { $0.submaps = ["resize"] }
        #expect(manager.dispatch(.submap("resize")) == [.submap("resize")])
        #expect(manager.submap == "resize")
        #expect(manager.dispatch(.submap("reset")) == [.submap("")])
        #expect(manager.dispatch(.submap("nope")) == [.failed("submap \"nope\" is not defined")])

        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.layoutMessage("togglesplit"))
        #expect(manager.computePlan().frame(of: 2)?.minY == 413)
        if case .failed = manager.dispatch(.layoutMessage("mfact 0.1")).first {} else {
            Issue.record("mfact is not a dwindle message")
        }
    }

    @Test func monitorUnplugMovesWorkspaces() {
        let manager = makeManager(monitors: [primary, external])
        manager.addWindow(info(1, frame: CGRect(x: 1200, y: 100, width: 400, height: 300)), isNew: false)
        manager.setMonitors([primary])
        #expect(manager.workspaces[.numbered(2)]?.monitorID == 1)
        #expect(manager.monitorStates[2] == nil)
        if case .hidden = manager.computePlan().placements[1] {} else {
            Issue.record("workspace 2 is hidden on the remaining monitor")
        }
        manager.setMonitors([primary, external])
        #expect(manager.monitorStates[2]?.activeWorkspace == .numbered(2))
        #expect(manager.computePlan().frame(of: 1) == external.visibleFrame)
    }

    @Test func titleChangesReapplyDynamicRules() throws {
        let manager = makeManager { config in
            var r = try! rule { match, effects in
                match.title = try RulePattern("Picture-in-Picture")
                effects.float = true
                effects.borderSize = 4
            }
            r.dynamic = true
            config.windowRules = [r]
        }
        manager.addWindow(info(1, title: "Video"), isNew: true)
        #expect(manager.windows[1]?.isFloating == false)
        manager.updateInfo(info(1, title: "Picture-in-Picture"))
        #expect(manager.windows[1]?.isFloating == true)
        #expect(manager.windows[1]?.borderSize == 4)
    }

    @Test func eventLinesUseHyprlandNames() {
        #expect(WMEvent.workspace(.numbered(3)).line == "workspace>>3")
        #expect(WMEvent.openWindow(255, workspace: .numbered(1), bundleID: "com.a", title: "T").line == "openwindow>>ff,1,com.a,T")
        #expect(WMEvent.activeSpecial("scratch", monitorName: "DELL").line == "activespecial>>special:scratch,DELL")
    }

    @Test func pointerHelpers() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.addWindow(info(3, resizable: false), isNew: true)
        let plan = manager.computePlan()
        #expect(manager.window(at: CGPoint(x: 200, y: 200), plan: plan) == 3, "floating windows sit on top")
        #expect(manager.window(at: CGPoint(x: 50, y: 700), plan: plan) == 1)
        #expect(manager.focusFromCursor(1) == [.focus(1)])
        #expect(manager.focusFromCursor(1).isEmpty)
        manager.swapWindows(1, 2)
        #expect(manager.computePlan().frame(of: 1)?.minX == 500)
        manager.swapWindows(1, 3)
        #expect(manager.computePlan().frame(of: 1)?.minX == 500, "floating windows do not swap")
    }

    @Test func revealFramesBringParkedWindowsBack() {
        let manager = makeManager(monitors: [primary, external])
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2, resizable: false), isNew: true)
        manager.dispatch(.focusWorkspace(.id(.numbered(3)), onCurrentMonitor: false))
        let frames = manager.revealFrames()
        #expect(frames[1] == CGRect(x: 40, y: 65, width: 400, height: 300))
        #expect(frames[2] == CGRect(x: 100, y: 100, width: 400, height: 300), "floating windows return to their own frame")
    }

    @Test func floatingMovesAndRuleToggles() throws {
        let manager = makeManager { config in
            config.windowRules = [try! rule { match, effects in
                match.class = try RulePattern("app")
                effects.borderSize = 7
            }]
        }
        manager.addWindow(info(1, resizable: false), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.floatingWindowMoved(1, frame: CGRect(x: 10, y: 40, width: 300, height: 200))
        manager.floatingWindowMoved(2, frame: CGRect(x: 10, y: 40, width: 300, height: 200))
        #expect(manager.computePlan().frame(of: 1) == CGRect(x: 10, y: 40, width: 300, height: 200))
        #expect(manager.computePlan().frame(of: 2) == CGRect(x: 0, y: 25, width: 1000, height: 775), "tiled windows ignore it")
        manager.windowFrameChanged(2, frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        #expect(manager.windows[2]?.info.frame.size == CGSize(width: 640, height: 480))
        #expect(manager.windows[2]?.borderSize == 7)
        manager.setWindowRuleEnabled(0, false)
        #expect(manager.windows[2]?.borderSize == nil)
    }

    @Test func adoptedWindowsSpiralInsteadOfSplittingTheFirstTile() {
        let manager = makeManager()
        for id: WindowID in 1...4 { manager.addWindow(info(id), isNew: false) }
        let plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 500, height: 775))
        #expect(plan.frame(of: 2)?.size == CGSize(width: 500, height: 388))
        #expect(plan.frame(of: 3)?.size == CGSize(width: 250, height: 388))
        #expect(plan.frame(of: 4)?.size == CGSize(width: 250, height: 388))
    }

    @Test func newWindowsOpenSilentlyByDefault() throws {
        let manager = makeManager { config in
            config.focusOnOpen = false
            config.windowRules = [try! rule { match, effects in
                match.title = try RulePattern("^Mail")
                effects.workspace = WorkspaceTarget(parsing: "6")
            }]
        }
        #expect(manager.addWindow(info(1), isNew: true).isEmpty)
        #expect(manager.focusedWindow == nil)
        manager.externalFocus(1)
        #expect(manager.addWindow(info(2), isNew: true).isEmpty)
        #expect(manager.focusedWindow == 1, "focus stays put")
        #expect(manager.computePlan().frame(of: 2)?.width == 500, "but the window still tiles")
        #expect(manager.addWindow(info(3, title: "Mail - Inbox"), isNew: true).isEmpty)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1), "a non-silent rule does not switch either")
        #expect(manager.windows[3]?.workspace == .numbered(6))
    }

    @Test func silentlyOpenedWindowsGiveTheKeyboardBack() throws {
        let manager = makeManager { config in
            config.focusOnOpen = false
            config.windowRules = [try! rule { match, effects in
                match.title = try RulePattern("^Mail")
                effects.workspace = WorkspaceTarget(parsing: "6 silent")
            }]
        }
        manager.addWindow(info(1), isNew: true)
        manager.externalFocus(1)
        #expect(manager.addWindow(info(2, title: "Mail - Inbox"), isNew: true).isEmpty)
        // macOS keys the new window on the hidden workspace
        let managed = KeyboardOwner(pid: 101, window: 1)
        #expect(manager.externalFocus(2, justOpened: true, previousOwner: managed) == [.focus(1)],
                "the keyboard goes back to the previous window")
        #expect(manager.focusedWindow == 1)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1), "without switching workspace")

        // the keyboard was on an unmanaged app (Ghostty), not on the model's last focused window
        manager.addWindow(info(3, title: "Mail - Drafts"), isNew: true)
        let ghostty = KeyboardOwner(pid: 999, window: 50)
        #expect(manager.externalFocus(3, justOpened: true, previousOwner: ghostty) == [.activate(pid: 999, window: 50)],
                "Ghostty gets it back, not window 1")
        #expect(manager.focusedWindow == 1)
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))

        manager.addWindow(info(4, title: "Mail - Sent"), isNew: true)
        #expect(manager.externalFocus(4, justOpened: true).isEmpty, "no known owner: nothing to give back")
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(1))

        #expect(manager.externalFocus(2) == [], "a later click on it still switches there")
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(6))
        #expect(manager.focusedWindow == 2)
    }

    @Test func focusOnOpenFollowsNewWindows() throws {
        let manager = makeManager { config in
            config.focusOnOpen = true
            config.windowRules = [try! rule { match, effects in
                match.title = try RulePattern("^Mail")
                effects.workspace = WorkspaceTarget(parsing: "6")
            }]
        }
        #expect(manager.addWindow(info(1), isNew: true) == [.focus(1)])
        #expect(manager.addWindow(info(3, title: "Mail - Inbox"), isNew: true) == [.focus(3)])
        #expect(manager.monitorStates[1]?.activeWorkspace == .numbered(6))
    }

    @Test func unmanagedAppsAreNeverTouched() {
        let manager = makeManager { $0.unmanagedApps = ["com.mitchellh.ghostty"] }
        #expect(manager.addWindow(info(1, bundle: "com.mitchellh.ghostty"), isNew: true).isEmpty)
        #expect(manager.windows[1] == nil)
        #expect(manager.externalFocus(1).isEmpty)
        manager.addWindow(info(2), isNew: true)
        var config = manager.config
        config.unmanagedApps = ["com.example.app"]
        manager.setConfig(config)
        #expect(manager.windows[2] == nil, "becoming unmanaged releases the window")
    }

    @Test func becomingUnmanagedUnparksAndKeepsTheKeyboard() throws {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2, bundle: "com.mitchellh.ghostty"), isNew: true)
        manager.addWindow(info(3, bundle: "com.mitchellh.ghostty"), isNew: true)
        manager.dispatch(.moveToWorkspace(.id(.numbered(4)), follow: false))
        manager.externalFocus(2)
        #expect(manager.windows[3]?.workspace == .numbered(4))
        _ = manager.drainEvents()

        var config = manager.config
        config.unmanagedApps = ["com.mitchellh.ghostty"]
        let released = manager.setConfig(config)
        #expect(manager.windows[2] == nil && manager.windows[3] == nil)
        #expect(released.map(\.info.id) == [3], "only the parked window needs bringing back")
        let frame = try #require(released.first?.frame)
        #expect(primary.visibleFrame.contains(frame))
        #expect(manager.focusedWindow == nil, "no fallback focus steals the keyboard from the released window")
        #expect(manager.drainEvents().contains(.activeWindow(nil, bundleID: "", title: "")))
    }

    @Test func cycleLayoutFollowsTmuxAndSurvivesReloads() {
        let manager = makeManager()
        for id: WindowID in 1...4 { manager.addWindow(info(id), isNew: true) }
        var seen: [LayoutKind] = []
        for _ in 0..<LayoutKind.defaultCycle.count {
            manager.dispatch(.cycleLayout(reverse: false))
            seen.append(manager.workspaces[.numbered(1)]!.layout.kind)
        }
        #expect(seen == Array(LayoutKind.defaultCycle.dropFirst()) + [.dwindle], "dwindle, then tmux's next-layout order, wrapping")
        manager.dispatch(.cycleLayout(reverse: true))
        #expect(manager.workspaces[.numbered(1)]?.layout.kind == .tiled)
        #expect(manager.workspaces[.numbered(1)]?.layout.windows == [1, 2, 3, 4], "window order carries over")
        manager.dispatch(.cycleLayout(reverse: true))
        #expect(manager.workspaces[.numbered(1)]?.layout.kind == .mainVerticalMirrored)
        let plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 450, y: 25, width: 550, height: 775), "main on the right")

        var config = manager.config
        config.layoutOptions.master.orientation = .top
        manager.setConfig(config)
        #expect(manager.workspaces[.numbered(1)]?.layout.kind == .mainVerticalMirrored, "a chosen main-* keeps its side")
    }

    @Test func cycleLayoutFromMasterContinuesAtItsSide() {
        let manager = makeManager { $0.layout = .master; $0.layoutOptions.master.orientation = .top }
        for id: WindowID in 1...3 { manager.addWindow(info(id), isNew: true) }
        manager.dispatch(.cycleLayout(reverse: false))
        #expect(manager.workspaces[.numbered(1)]?.layout.kind == .mainHorizontalMirrored, "master on top is main-horizontal")
    }

    @Test func liveLayoutsKeepTheirShapeAsWindowsComeAndGo() {
        let manager = makeManager { $0.layout = .tiled }
        for id: WindowID in 1...3 { manager.addWindow(info(id), isNew: true) }
        var plan = manager.computePlan()
        // tmux's tiled with 3: a row of 2, then 1 full width
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 500, height: 388))
        #expect(plan.frame(of: 3) == CGRect(x: 0, y: 413, width: 1000, height: 388))
        manager.addWindow(info(4), isNew: true)
        plan = manager.computePlan()
        #expect(plan.frame(of: 4)?.width == 500, "still a grid: 2 x 2")
        manager.removeWindow(2)
        manager.removeWindow(3)
        plan = manager.computePlan()
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 1000, height: 388), "2 windows: stacked")
    }

    @Test func minimumSizesMoveSplitsAndTheNewestFloatsWhenTheyCannotFit() {
        let manager = makeManager()
        for id: WindowID in 1...3 { manager.addWindow(info(id, bundle: id == 3 ? "com.brave.Browser" : "com.example.app"), isNew: true) }
        // dwindle: 1 | (2 / 3), each right tile 500 wide
        #expect(manager.computePlan().frame(of: 3)?.width == 500)
        #expect(manager.windowRefusedSize(3, minimum: CGSize(width: 700, height: 0)))
        #expect(!manager.windowRefusedSize(3, minimum: CGSize(width: 650, height: 0)), "minimums only grow")
        var plan = manager.computePlan()
        #expect(plan.frame(of: 3) == CGRect(x: 300, y: 413, width: 700, height: 388))
        #expect(plan.frame(of: 1) == CGRect(x: 0, y: 25, width: 300, height: 775), "2 and 3 share the widened column; 1 gives way")
        #expect(plan.overflow.isEmpty)

        // the app's next window starts with what was learned
        manager.addWindow(info(4, bundle: "com.brave.Browser"), isNew: true)
        #expect(manager.windows[4]?.minimumSize == CGSize(width: 700, height: 0))
        plan = manager.computePlan()
        #expect(plan.overflow == [4], "two 700-wide windows cannot share 1000: the newest floats")
        #expect(plan.frame(of: 4) == CGRect(x: 150, y: 263, width: 700, height: 300), "centred on top, at its minimum width")
        #expect(manager.window(at: CGPoint(x: 500, y: 400), plan: plan) == 4, "it sits above the tiles")
        #expect(manager.workspaces[.numbered(1)]?.layout.windows.contains(4) == true, "still tiled in the model")

        // room again: it drops back into its tile
        manager.removeWindow(3)
        plan = manager.computePlan()
        #expect(plan.overflow.isEmpty)
        #expect(plan.frame(of: 4)?.width == 700)

        // re-tile measures again
        manager.dispatch(.retile)
        #expect(manager.windows[4]?.minimumSize == .zero)
        #expect(manager.appMinimumSizes.isEmpty)
    }

    @Test func windowsWithoutAMinimumKeepASmallestTile() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.windowRefusedSize(2, minimum: CGSize(width: 990, height: 0))
        let plan = manager.computePlan()
        #expect(plan.overflow == [2], "990 + the 120 floor do not fit 1000")
        #expect(plan.frame(of: 1)?.width == 1000)
    }

    @Test func minSizeRuleAndReportedMinimum() throws {
        let rules = try [rule { match, effects in
            match.class = try RulePattern("chat")
            effects.minSize = "monitor_w*0.6 100"
        }]
        let manager = makeManager { $0.windowRules = rules }
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2, bundle: "com.example.chat"), isNew: true)
        #expect(manager.windows[2]?.minimumSize == CGSize(width: 600, height: 100))
        #expect(manager.computePlan().frame(of: 2)?.width == 600)
        var reported = info(1)
        reported.minSize = CGSize(width: 450, height: 0)
        manager.updateInfo(reported)
        #expect(manager.computePlan().frame(of: 1)?.width == 1000, "450 + 600 cannot share 1000: 1 tiles alone")
        #expect(manager.computePlan().overflow == [2], "450 + 600 > 1000: the newest floats")

        // a min_size rule added by a reload applies to windows already open
        var config = manager.config
        config.windowRules = try [rule { match, effects in
            match.class = try RulePattern("example\\.app")
            effects.minSize = "300 0"
        }]
        manager.setConfig(config)
        #expect(manager.windows[1]?.ruleMinSize == CGSize(width: 300, height: 0))
        #expect(manager.windows[2]?.ruleMinSize == nil, "the chat rule is gone")
    }

    @Test func cycleNextVisitsFloatingWindows() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.float(.set))
        manager.addWindow(info(3), isNew: true)
        manager.dispatch(.float(.set))
        manager.markFocused(1)
        #expect(manager.dispatch(.cycleWindows(.floating, reverse: false)).first == .focus(2))
        #expect(manager.dispatch(.cycleWindows(.floating, reverse: false)).first == .focus(3))
        #expect(manager.dispatch(.cycleWindows(.floating, reverse: false)).first == .focus(2), "wraps")
        #expect(manager.dispatch(.cycleWindows(.tiled, reverse: false)).first == .focus(1))
        #expect(manager.dispatch(.cycleWindows(.all, reverse: true)).first == .focus(3))
    }

    @Test func layoutPreviewForHiddenWorkspaces() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        #expect(manager.layoutPreview(for: .numbered(1))[2] == CGRect(x: 500, y: 25, width: 500, height: 775))
        if case .hidden = manager.computePlan().placements[2] {} else { Issue.record("workspace 1 is hidden") }
    }

    @Test func tabSwitchReplacesTheWindowInPlace() {
        let manager = makeManager()
        manager.addWindow(info(1), isNew: true)
        manager.addWindow(info(2), isNew: true)
        manager.addWindow(info(3), isNew: true)
        let before = manager.computePlan().frame(of: 2)
        manager.externalFocus(2)
        #expect(manager.replaceWindow(2, with: info(9, title: "Tab 2")))
        #expect(manager.windows[2] == nil)
        #expect(manager.computePlan().frame(of: 9) == before)
        #expect(manager.focusedWindow == 9)
        #expect(!manager.replaceWindow(42, with: info(10)))
        #expect(!manager.replaceWindow(1, with: info(3)), "the new id is already managed")
    }
}
