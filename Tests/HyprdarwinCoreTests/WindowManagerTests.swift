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

    @Test func perWorkspaceLayoutAndConfigReload() {
        let manager = makeManager { config in
            var r = WorkspaceRule(workspace: .numbered(2))
            r.layout = .master
            config.workspaceRules = [r]
        }
        manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))
        for id: WindowID in 1...3 { manager.addWindow(info(id), isNew: true) }
        #expect(manager.workspaces[.numbered(2)]?.layout.kind == .master)
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
}
