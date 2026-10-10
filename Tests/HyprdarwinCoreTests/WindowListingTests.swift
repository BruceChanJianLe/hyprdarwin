import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinCore

private let screen = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                             visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
private let brave: Int32 = 300
private let safari: Int32 = 400
private let ghostty: Int32 = 500

private func terminal(_ id: WindowID) -> WindowInfo {
    window(id, pid: ghostty, bundle: "com.mitchellh.ghostty")
}

/// The captain's config: Brave opens on workspace 7.
private func braveOnSeven(_ config: inout Config) {
    var match = WindowRuleMatch()
    match.class = try? RulePattern("com\\.brave\\.Browser")
    var effects = WindowRuleEffects()
    effects.workspace = WorkspaceTarget(parsing: "7 silent")
    config.windowRules = [WindowRule(match: match, effects: effects)]
}

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
private let start = Date(timeIntervalSinceReferenceDate: 0)

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

/// Every 0.25 s probe tick from `from` up to `to`, returning the times a re-list was asked.
private func ticks(_ probe: inout ListingProbe, from: TimeInterval, to: TimeInterval, listed: [Int32: Set<WindowID>],
                   onScreen: [WindowID: ScreenWindow]) -> [TimeInterval] {
    var asked: [TimeInterval] = []
    for tick in stride(from: from, through: to, by: 0.25)
    where !probe.appsToRelist(listed: listed, onScreen: onScreen, now: at(tick)).isEmpty {
        asked.append(tick)
    }
    return asked
}

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
        var probe = ListingProbe()
        let both: [WindowID: ScreenWindow] = [1: ScreenWindow(pid: brave), 2: ScreenWindow(pid: brave)]
        #expect(probe.appsToRelist(listed: [brave: listed], onScreen: both, now: at(0)).isEmpty)

        // closed: ordered out but alive, so only the window server knows
        #expect(probe.appsToRelist(listed: [brave: listed], onScreen: [2: ScreenWindow(pid: brave)], now: at(0.25)) == [brave])
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

    @Test func newWindowNotYetListedAsksForARelist() {
        var probe = ListingProbe()
        let listed: [Int32: Set<WindowID>] = [brave: [1], safari: []]
        var onScreen: [WindowID: ScreenWindow] = [1: ScreenWindow(pid: brave)]
        #expect(probe.appsToRelist(listed: listed, onScreen: onScreen, now: at(0)).isEmpty)
        onScreen[3] = ScreenWindow(pid: brave)
        onScreen[4] = ScreenWindow(pid: brave, layer: 101)
        onScreen[5] = ScreenWindow(pid: 999)
        #expect(probe.appsToRelist(listed: listed, onScreen: onScreen, now: at(0.25)) == [brave],
                "a menu and a window of an app without a worker do not count")
        onScreen[6] = ScreenWindow(pid: safari)
        #expect(probe.appsToRelist(listed: listed, onScreen: onScreen, now: at(0.3)) == [safari], "an app listing no windows yet still counts")
        #expect(probe.appsToRelist(listed: [brave: [1, 3], safari: [6]], onScreen: onScreen, now: at(0.5)).isEmpty)
    }

    @Test func closingTheFocusedWindowFocusesTheOtherOne() {
        let (manager, listed) = twoBraveWindows()
        let changes = manager.applyListing([window(1)], previous: listed, initial: false)
        #expect(changes == [.removed(2, effects: [.focus(1)])])
        #expect(manager.focusedWindow == 1)
    }

    /// Brave is busy when the first re-list is asked, so no list arrives:
    /// the probe asks again on the backoff and the next list drops the tile.
    @Test func busyAppWithNoListingIsAskedAgain() {
        let (manager, listed) = twoBraveWindows()
        var probe = ListingProbe()
        let closed: [WindowID: ScreenWindow] = [2: ScreenWindow(pid: brave)]
        #expect(probe.appsToRelist(listed: [brave: listed], onScreen: closed, now: at(0)) == [brave])
        #expect(probe.appsToRelist(listed: [brave: listed], onScreen: closed, now: at(0.1)).isEmpty, "not yet due")
        #expect(probe.appsToRelist(listed: [brave: listed], onScreen: closed, now: at(0.25)) == [brave])
        manager.applyListing([window(2)], previous: listed, initial: false)
        #expect(manager.windows[1] == nil)
        #expect(probe.appsToRelist(listed: [brave: [2]], onScreen: closed, now: at(0.5)).isEmpty)
    }

    /// The closed window is still in Brave's list for a while: each re-list
    /// comes back unchanged until Brave drops it.
    @Test func staleListingAfterCloseKeepsAsking() {
        var probe = ListingProbe()
        let listed: [Int32: Set<WindowID>] = [brave: [1, 2]]
        let closed: [WindowID: ScreenWindow] = [2: ScreenWindow(pid: brave)]
        #expect(ticks(&probe, from: 0, to: 2, listed: listed, onScreen: closed) == [0, 0.25, 0.75, 1.75])
        #expect(ticks(&probe, from: 2.25, to: 3, listed: [brave: [2]], onScreen: closed).isEmpty)
    }

    /// Brave lists a new window late, after the first re-list.
    @Test func lateListedNewWindowKeepsAsking() {
        let manager = makeManager()
        manager.applyListing([window(1)], previous: [], initial: true)
        var probe = ListingProbe()
        let onScreen: [WindowID: ScreenWindow] = [1: ScreenWindow(pid: brave), 3: ScreenWindow(pid: brave)]
        #expect(ticks(&probe, from: 0, to: 0.5, listed: [brave: [1]], onScreen: onScreen) == [0, 0.25])
        #expect(ticks(&probe, from: 0.75, to: 0.75, listed: [brave: [1]], onScreen: onScreen) == [0.75])
        let changes = manager.applyListing([window(1), window(3)], previous: [1], initial: false)
        guard case .added(3, isNew: true, _) = changes.first else { Issue.record("the late window opens"); return }
        #expect(ticks(&probe, from: 1, to: 2, listed: [brave: [1, 3]], onScreen: onScreen).isEmpty)
    }

    /// A window that never agrees (an unlisted dialog) asks on the backoff,
    /// then is left to the periodic re-list until it clears.
    @Test func probeGivesUpAfterTheBackoff() {
        var probe = ListingProbe()
        let listed: [Int32: Set<WindowID>] = [brave: [1]]
        let dialog: [WindowID: ScreenWindow] = [1: ScreenWindow(pid: brave), 8: ScreenWindow(pid: brave)]
        #expect(ticks(&probe, from: 0, to: 30, listed: listed, onScreen: dialog) == [0, 0.25, 0.75, 1.75, 3.75, 7.75])
        // it clears, then appears again: a fresh disagreement
        #expect(ticks(&probe, from: 30.25, to: 30.25, listed: listed, onScreen: [1: ScreenWindow(pid: brave)]).isEmpty)
        #expect(ticks(&probe, from: 30.5, to: 31, listed: listed, onScreen: dialog) == [30.5, 30.75])
    }

    @Test func probeTracksEachDisagreementOnItsOwn() {
        var probe = ListingProbe()
        let listed: [Int32: Set<WindowID>] = [brave: [1, 2], safari: [5]]
        func shown(_ ids: [WindowID]) -> [WindowID: ScreenWindow] {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, ScreenWindow(pid: $0 == 5 ? safari : brave)) })
        }
        #expect(probe.appsToRelist(listed: listed, onScreen: shown([2, 5]), now: at(0)) == [brave])
        #expect(probe.appsToRelist(listed: listed, onScreen: shown([2]), now: at(0.1)) == [safari], "a new disagreement asks at once")
        #expect(probe.appsToRelist(listed: listed, onScreen: shown([2]), now: at(0.25)) == [brave])
        #expect(probe.appsToRelist(listed: listed, onScreen: shown([1, 2]), now: at(0.35)) == [safari])
        #expect(probe.appsToRelist(listed: listed, onScreen: shown([1, 2, 5]), now: at(0.5)).isEmpty)
        // another Space: everything leaves the screen and each app re-lists
        #expect(probe.appsToRelist(listed: listed, onScreen: [:], now: at(1)) == [brave, safari])
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

    /// The captain's report: a trip to another macOS Space and back. Apps
    /// list only the current Space's windows, so while away every window
    /// leaves the lists, yet each keeps its workspace and tile order, and on
    /// return nothing opens again or lands on another workspace.
    @Test func spaceTripKeepsWorkspacesAndTileOrder() {
        let manager = makeManager()
        manager.applyListing([window(1), window(2), window(3)], previous: [], initial: true)
        manager.applyListing([window(5, pid: safari, bundle: "com.apple.Safari")], previous: [], initial: true)
        manager.externalFocus(3)
        _ = manager.dispatch(.moveToWorkspace(.id(.numbered(8)), follow: false))
        manager.externalFocus(2)
        let layouts = manager.workspaces.mapValues(\.layout)
        let assigned = manager.windows.mapValues(\.workspace)
        let plan = manager.computePlan()

        // on another Space: nothing is listed, every window is still on a Space
        let braveAway = manager.applyListing([], away: [1, 2, 3], previous: [1, 2, 3], initial: false)
        let safariAway = manager.applyListing([], away: [5], previous: [5], initial: false)
        #expect(braveAway == [.away(1), .away(2), .away(3)] && safariAway == [.away(5)])
        #expect(manager.windows.mapValues(\.workspace) == assigned)
        #expect(manager.computePlan().placements.isEmpty, "nothing is written or parked while away")
        #expect(manager.focusedWindow == nil)
        // a window over there tiles alone: the away ones take no room
        let opened = manager.applyListing([window(7, pid: safari, bundle: "com.apple.Safari")], away: [5], previous: [5], initial: false)
        guard case .added(7, isNew: true, _) = opened.first else { Issue.record("a new window on the other Space"); return }
        #expect(manager.computePlan().frame(of: 7) == screen.visibleFrame)

        // back: listed again (window 7 is now the one away)
        let braveBack = manager.applyListing([window(1), window(2), window(3)], previous: [1, 2, 3], initial: false)
        let safariBack = manager.applyListing([window(5, pid: safari, bundle: "com.apple.Safari")], away: [7], previous: [5, 7], initial: false)
        #expect(braveBack == [.returned(1), .returned(2), .returned(3)])
        #expect(safariBack == [.away(7), .returned(5)])
        #expect(manager.windows.filter { $0.key != 7 }.mapValues(\.workspace) == assigned)
        #expect(manager.workspaces[.numbered(8)]?.layout == layouts[.numbered(8)])
        let order = manager.workspaces[.numbered(1)]?.layout.windows ?? []
        #expect(order.filter { $0 != 7 } == layouts[.numbered(1)]?.windows, "the tile order is kept")
        let back = manager.computePlan()
        for id in [1, 2, 3, 5] as [WindowID] { #expect(back.placements[id] == plan.placements[id], "window \(id) is where it was") }
        #expect(back.placements[7] == nil)
    }

    /// Window 2 goes native fullscreen: it moves to its own Space, where its
    /// app lists it as fullscreen and the others not at all. Back on the
    /// desktop the others share the room; when it leaves fullscreen it takes
    /// its old tile again.
    @Test func nativeFullscreenEnterAndExitKeepsThePlace() {
        let manager = makeManager()
        manager.applyListing([window(1), window(2), window(3)], previous: [], initial: true)
        manager.externalFocus(2)
        let layout = manager.workspaces[.numbered(1)]?.layout
        let plan = manager.computePlan()

        // on its fullscreen Space: 2 is listed but fullscreen, 1 and 3 elsewhere
        #expect(manager.applyListing([], away: [1, 2, 3], previous: [1, 2, 3], initial: false) == [.away(1), .away(2), .away(3)])
        #expect(manager.externalFocus(2).isEmpty && manager.focusedWindow == nil, "the keyboard on it changes no workspace")
        // swiping back to the desktop while it stays fullscreen
        #expect(manager.applyListing([window(1), window(3)], away: [2], previous: [1, 2, 3], initial: false) == [.returned(1), .returned(3)])
        let desktop = manager.computePlan()
        #expect(desktop.placements[2] == nil)
        #expect(desktop.frame(of: 1).map { $0.width + desktop.frame(of: 3)!.width } == screen.visibleFrame.width, "no gap where 2 was")
        for direction in [Direction.left, .right, .up, .down] {
            #expect(!manager.dispatch(.focusDirection(direction)).contains(.focus(2)))
        }
        #expect(!manager.dispatch(.cycleWindows(.all, reverse: false)).contains(.focus(2)))

        // it leaves fullscreen
        #expect(manager.applyListing([window(1), window(2), window(3)], previous: [1, 2, 3], initial: false) == [.returned(2)])
        #expect(manager.workspaces[.numbered(1)]?.layout == layout)
        #expect(manager.computePlan() == plan)
    }

    /// The captain's first case: Brave, which a rule opens on workspace 7,
    /// moved by hand to workspace 3 beside Ghostty. Ghostty goes native
    /// fullscreen and back: Brave stays in its tile on 3, because rules run
    /// only for windows that just opened, never for ones coming back.
    @Test func braveMovedBesideGhosttyStaysThroughGhosttyFullscreen() {
        let manager = makeManager(braveOnSeven)
        _ = manager.dispatch(.focusWorkspace(.id(.numbered(3)), onCurrentMonitor: false))
        manager.applyListing([terminal(50)], previous: [], initial: false)
        manager.applyListing([window(1)], previous: [], initial: false)
        #expect(manager.windows[1]?.workspace == .numbered(7), "the rule places a new Brave window")
        manager.externalFocus(1)
        _ = manager.dispatch(.moveToWorkspace(.id(.numbered(3)), follow: true))
        #expect(manager.windows[1]?.workspace == .numbered(3) && manager.isVisible(.numbered(3)))
        let layouts = manager.workspaces.mapValues(\.layout)
        let plan = manager.computePlan()

        // Ghostty's fullscreen Space: it is listed fullscreen, Brave not at all
        #expect(manager.applyListing([], away: [50], previous: [50], initial: false) == [.away(50)])
        #expect(manager.applyListing([], away: [1], previous: [1], initial: false) == [.away(1)])
        // out of fullscreen
        #expect(manager.applyListing([terminal(50)], previous: [50], initial: false) == [.returned(50)])
        #expect(manager.applyListing([window(1)], previous: [1], initial: false) == [.returned(1)])

        #expect(manager.windows[1]?.workspace == .numbered(3))
        #expect(manager.workspaces.mapValues(\.layout) == layouts)
        #expect(manager.computePlan() == plan)
    }

    /// The captain's second case: three Brave windows tiled on workspace 7
    /// (Ghostty on 1). One goes native fullscreen and back: all three are in
    /// the same tiles in the same order, and nothing else moves.
    @Test func threeBraveWindowsKeepTheirTilesThroughOneFullscreen() {
        let manager = makeManager(braveOnSeven)
        manager.applyListing([terminal(50)], previous: [], initial: true)
        manager.applyListing([window(1)], previous: [], initial: false)
        manager.applyListing([window(1), window(2)], previous: [1], initial: false)
        manager.applyListing([window(1), window(2), window(3)], previous: [1, 2], initial: false)
        _ = manager.dispatch(.focusWorkspace(.id(.numbered(7)), onCurrentMonitor: false))
        manager.externalFocus(2)
        #expect(manager.workspaces[.numbered(7)]?.layout.windows.count == 3)
        let assigned = manager.windows.mapValues(\.workspace)
        let layouts = manager.workspaces.mapValues(\.layout)
        let plan = manager.computePlan()

        // window 2's fullscreen Space: Brave lists only 2, as fullscreen
        manager.applyListing([], away: [1, 2, 3], previous: [1, 2, 3], initial: false)
        manager.applyListing([], away: [50], previous: [50], initial: false)
        // back out: Brave relists all three, Ghostty (parked on 1) again
        let back = manager.applyListing([window(1), window(2), window(3)], previous: [1, 2, 3], initial: false)
        manager.applyListing([terminal(50)], previous: [50], initial: false)
        #expect(back == [.returned(1), .returned(2), .returned(3)], "nothing reopens, so no rule runs")

        #expect(manager.windows.mapValues(\.workspace) == assigned)
        #expect(manager.workspaces.mapValues(\.layout) == layouts)
        #expect(manager.computePlan() == plan)
    }

    /// The captain's log (2026-10-10 03:29:34-36): Brave 20482, moved by hand
    /// to workspace 3 beside Ghostty, goes native fullscreen. Brave first
    /// does not list it while it is still on a Space, then, mid-transition,
    /// neither lists it nor has it on any Space. That second listing used to
    /// close it, so on return it reopened: the Brave rule sent it to 7 and
    /// the tiles reflowed. Now it stays away until it is listed again.
    @Test func fullscreeningWindowBrieflyOnNoSpaceKeepsItsPlace() {
        let manager = makeManager(braveOnSeven)
        _ = manager.dispatch(.focusWorkspace(.id(.numbered(3)), onCurrentMonitor: false))
        manager.applyListing([terminal(18935)], previous: [], initial: false)
        manager.applyListing([window(20482)], previous: [], initial: false)
        manager.externalFocus(20482)
        _ = manager.dispatch(.moveToWorkspace(.id(.numbered(3)), follow: true))
        let layouts = manager.workspaces.mapValues(\.layout)
        let plan = manager.computePlan()
        var departures = DepartureTracker()

        // 34.854: not listed, still on a Space
        #expect(departures.verdict(for: 20482, onASpace: true, onScreen: true, now: at(0)) == .away)
        #expect(manager.applyListing([], away: [20482], previous: [20482], initial: false) == [.away(20482)])
        // 35.327: the fullscreen Space is shown, Ghostty's window is elsewhere
        #expect(departures.verdict(for: 18935, onASpace: true, onScreen: false, now: at(0.47)) == .away)
        #expect(manager.applyListing([], away: [18935], previous: [18935], initial: false) == [.away(18935)])
        // 35.720: on its way, Brave's window is on no Space for a moment
        #expect(departures.verdict(for: 20482, onASpace: false, onScreen: false, now: at(0.87)) == .closing(recheckAfter: 1))
        #expect(manager.applyListing([], away: [20482], previous: [20482], initial: false).isEmpty, "not closed")
        // 36.236: back on the desktop, both listed again
        departures.forget(20482)
        departures.forget(18935)
        #expect(manager.applyListing([terminal(18935)], previous: [18935], initial: false) == [.returned(18935)])
        #expect(manager.applyListing([window(20482)], previous: [20482], initial: false) == [.returned(20482)])

        #expect(manager.windows[20482]?.workspace == .numbered(3), "no rule ran: it did not reopen")
        #expect(manager.workspaces.mapValues(\.layout) == layouts)
        #expect(manager.computePlan() == plan)
    }

    /// A window closed for real (ordered out, on no Space) leaves the tiling
    /// at once, and is gone once it has stayed off every Space for the
    /// grace; focus then falls back as for any closed window.
    @Test func realCloseIsConfirmedAfterTheGrace() {
        let (manager, listed) = twoBraveWindows()
        var departures = DepartureTracker()
        #expect(departures.verdict(for: 2, onASpace: false, onScreen: false, now: at(0)) == .closing(recheckAfter: 1))
        manager.applyListing([window(1)], away: [2], previous: listed, initial: false)
        #expect(manager.computePlan().frame(of: 1) == screen.visibleFrame, "the others take the room at once")
        #expect(departures.verdict(for: 2, onASpace: false, onScreen: false, now: at(0.5)) == .closing(recheckAfter: 0.5))
        #expect(departures.verdict(for: 2, onASpace: false, onScreen: false, now: at(1.05)) == .closed)
        let changes = manager.applyListing([window(1)], previous: listed, initial: false)
        #expect(changes == [.removed(2, effects: [.focus(1)])])
        #expect(manager.windows[2] == nil && manager.focusedWindow == 1)
    }

    @Test func departureBackOnASpaceOrOnScreenRestartsTheGrace() {
        var departures = DepartureTracker()
        #expect(departures.verdict(for: 5, onASpace: false, onScreen: false, now: at(0)) == .closing(recheckAfter: 1))
        #expect(departures.verdict(for: 5, onASpace: false, onScreen: true, now: at(0.5)) == .away)
        #expect(departures.verdict(for: 5, onASpace: false, onScreen: false, now: at(1.2)) == .closing(recheckAfter: 1))
        #expect(departures.verdict(for: 5, onASpace: true, onScreen: false, now: at(1.5)) == .away)
        #expect(departures.verdict(for: 5, onASpace: false, onScreen: false, now: at(3)) == .closing(recheckAfter: 1))
        #expect(departures.verdict(for: 5, onASpace: false, onScreen: false, now: at(4)) == .closed)
    }

    /// A window closed for real is on no Space: it is not away, and goes at
    /// once, also while it was away and while other windows are away.
    @Test func realCloseStillDropsPromptly() {
        let manager = makeManager()
        manager.applyListing([window(1), window(2), window(3)], previous: [], initial: true)
        manager.externalFocus(3)
        #expect(manager.applyListing([window(1), window(3)], away: [], previous: [1, 2, 3], initial: false) == [.removed(2, effects: [])])
        #expect(manager.workspaces[.numbered(1)]?.layout.windows == [1, 3])

        // away, then closed over there (or before it came back)
        manager.applyListing([window(3)], away: [1], previous: [1, 3], initial: false)
        #expect(manager.applyListing([window(3)], away: [], previous: [1, 3], initial: false) == [.removed(1, effects: [])])
        #expect(manager.windows.keys.sorted() == [3])
    }

    /// Focusing a window on another Space would make macOS switch to it:
    /// focus fallbacks and workspace switches pass over away windows.
    @Test func awayWindowsAreNeverFocused() {
        let manager = makeManager()
        manager.applyListing([window(1), window(2), window(3)], previous: [], initial: true)
        manager.externalFocus(1)
        manager.externalFocus(2)
        manager.applyListing([window(2), window(3)], away: [1], previous: [1, 2, 3], initial: false)
        let effects = manager.applyListing([window(3)], away: [1], previous: [1, 2, 3], initial: false)
        #expect(effects == [.removed(2, effects: [.focus(3)])], "falls back to 3, not to the more recent 1")

        manager.externalFocus(3)
        _ = manager.dispatch(.moveToWorkspace(.id(.numbered(2)), follow: false))
        #expect(manager.focusedWindow == nil, "only an away window is left on workspace 1")
        #expect(!manager.dispatch(.focusLast).contains(.focus(1)))
        #expect(manager.dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false)).contains(.focus(3)))
        #expect(!manager.dispatch(.focusWorkspace(.id(.numbered(1)), onCurrentMonitor: false)).contains(.focus(1)))
    }

    @Test func emptyListingRemovesEverything() {
        let (manager, listed) = twoBraveWindows()
        let changes = manager.applyListing([], previous: listed, initial: false)
        #expect(changes.count == 2)
        #expect(manager.windows.isEmpty)
    }
}
