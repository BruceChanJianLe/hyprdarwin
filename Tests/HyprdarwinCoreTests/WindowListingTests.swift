import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinCore

private let screen = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                             visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
private let brave: Int32 = 300
private let safari: Int32 = 400

private func window(_ id: WindowID, pid: Int32 = brave, bundle: String = "com.brave.Browser",
                    frame: CGRect = CGRect(x: 100, y: 100, width: 400, height: 300)) -> WindowInfo {
    WindowInfo(id: id, pid: pid, bundleID: bundle, appName: "App", title: "Window \(id)",
               subrole: "AXStandardWindow", frame: frame, isResizable: true)
}

private func makeManager(_ configure: (inout Config) -> Void = { _ in }) -> WindowManager {
    var config = Config()
    config.gapsIn = Insets(all: 0)
    config.gapsOut = Insets(all: 0)
    configure(&config)
    let manager = WindowManager(config: config)
    manager.setMonitors([screen])
    return manager
}

/// Two Brave windows tiled side by side (1 left, 2 right), 2 focused, as
/// both the initial listing and the model have them.
private func twoBraveWindows() -> (WindowManager, listed: Set<WindowID>) {
    let manager = makeManager()
    let listed = [window(1), window(2)]
    manager.applyListing(listed, previous: [], initial: true)
    manager.externalFocus(2)
    return (manager, Set(listed.map(\.id)))
}

@Suite struct WindowListingTests {
    /// The reported bug: Brave closes window 1 without a destroyed
    /// notification. The probe sees it leave the screen, Brave re-lists
    /// without it, and its tile and focus target are gone.
    @Test func closedWindowWithoutDestroyedNotificationLeavesLayoutAndFocus() {
        let (manager, listed) = twoBraveWindows()
        var probe = VanishedWindowProbe()
        #expect(probe.appsToRelist(model: manager, onScreen: [1, 2]).isEmpty)

        // closed: ordered out but alive, so only the window server knows
        #expect(probe.appsToRelist(model: manager, onScreen: [2]) == [brave])
        let changes = manager.applyListing([window(2)], previous: listed, initial: false)
        #expect(changes == [.removed(1, effects: [])])

        #expect(manager.windows[1] == nil)
        #expect(manager.workspaces[.numbered(1)]?.layout.windows == [2])
        let plan = manager.computePlan()
        #expect(plan.placements[1] == nil, "no tile, so no border either")
        #expect(plan.frame(of: 2) == screen.visibleFrame)
        #expect(manager.focusedWindow == 2)
        let effects = manager.dispatch(.focusDirection(.left))
        #expect(!effects.contains(.focus(1)), "HYPR+left has no phantom to focus")
        #expect(manager.focusedWindow == 2)
    }

    @Test func closingTheFocusedWindowFocusesTheOtherOne() {
        let (manager, listed) = twoBraveWindows()
        let changes = manager.applyListing([window(1)], previous: listed, initial: false)
        #expect(changes == [.removed(2, effects: [.focus(1)])])
        #expect(manager.focusedWindow == 1)
    }

    @Test func probeAsksOncePerDisappearance() {
        let manager = makeManager()
        manager.applyListing([window(1), window(2)], previous: [], initial: true)
        manager.applyListing([window(5, pid: safari, bundle: "com.apple.Safari")], previous: [], initial: true)
        var probe = VanishedWindowProbe()
        #expect(probe.appsToRelist(model: manager, onScreen: [2, 5, 77]) == [brave], "unmanaged on-screen windows do not matter")
        #expect(probe.appsToRelist(model: manager, onScreen: [2, 5]).isEmpty, "still listed while off screen: no re-ask")
        #expect(probe.appsToRelist(model: manager, onScreen: [1, 2, 5]).isEmpty)
        #expect(probe.appsToRelist(model: manager, onScreen: [2]) == [brave, safari])
        // another Space: everything leaves the screen and each app re-lists once
        #expect(probe.appsToRelist(model: manager, onScreen: []) == [brave])
        #expect(probe.appsToRelist(model: manager, onScreen: []).isEmpty)
    }

    @Test func tabSwitchKeepsThePlace() {
        let manager = makeManager()
        let tabs = CGRect(x: 600, y: 100, width: 300, height: 300)
        manager.applyListing([window(1), window(2, frame: tabs)], previous: [], initial: true)
        let before = manager.computePlan().frame(of: 2)
        let changes = manager.applyListing([window(1), window(9, frame: tabs)], previous: [1, 2], initial: false)
        #expect(changes == [.replaced(old: 2, new: 9)])
        #expect(manager.computePlan().frame(of: 9) == before)
    }

    @Test func listingOpensFindsAndAdopts() {
        let manager = makeManager { $0.unmanagedApps = ["com.apple.Safari"] }
        let found = manager.applyListing([window(1)], previous: [], initial: true)
        #expect(found.count == 1)
        guard case .added(1, isNew: false, _) = found.first else { Issue.record("found at startup, not opened"); return }

        let opened = manager.applyListing([window(1), window(2)], previous: [1], initial: false)
        guard case .added(2, isNew: true, _) = opened.first else { Issue.record("a new window opens"); return }

        let safariWindow = window(5, pid: safari, bundle: "com.apple.Safari")
        #expect(manager.applyListing([safariWindow], previous: [], initial: false).isEmpty, "unmanaged apps stay out")
        _ = manager.setConfig(Config())
        let adopted = manager.applyListing([safariWindow], previous: [5], initial: false)
        guard case .added(5, isNew: false, _) = adopted.first else { Issue.record("seen before, so adopted"); return }
    }

    @Test func emptyListingRemovesEverything() {
        let (manager, listed) = twoBraveWindows()
        let changes = manager.applyListing([], previous: listed, initial: false)
        #expect(changes.count == 2)
        #expect(manager.windows.isEmpty)
    }
}
