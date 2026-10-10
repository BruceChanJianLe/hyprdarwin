import Foundation
import Testing
@testable import HyprdarwinConfig
@testable import HyprdarwinCore

/// The default config's resize mode, end to end through the Lua runtime and
/// the model: enter the submap with its bind, then press keys by name.
@Suite struct ResizeModeScenarioTests {
    private static let monitor = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))

    private func session(_ layout: String? = nil, windows: Int = 2) throws -> (WindowManager, Config) {
        var config = try #require(ConfigLoader.load(source: DefaultConfig.text, directory: NSTemporaryDirectory()).config)
        config.gapsIn = Insets(all: 0)
        config.gapsOut = Insets(all: 0)
        if let layout { config.layout = try #require(LayoutKind(rawValue: layout)) }
        let manager = WindowManager(config: config)
        manager.setMonitors([Self.monitor])
        for id in 1...windows {
            manager.addWindow(WindowInfo(id: WindowID(id), pid: 100 + Int32(id), bundleID: "com.example.app", appName: "App",
                                         title: "W\(id)", subrole: "AXStandardWindow",
                                         frame: CGRect(x: 100, y: 100, width: 400, height: 300), isResizable: true), isNew: true)
        }
        // HYPR + SHIFT + R enters resize mode
        let enter = try #require(config.binds.first { $0.submap == nil && $0.combo == (try? KeyCombo.parse("HYPR + SHIFT + R").get()) })
        if case let .dispatcher(d) = enter.action { manager.dispatch(d) }
        #expect(manager.submap == "resize")
        return (manager, config)
    }

    private func press(_ key: String, _ manager: WindowManager, _ config: Config) throws {
        let combo = try KeyCombo.parse(key).get()
        let bind = try #require(config.binds.first { $0.submap == manager.submap && $0.combo == combo }, "\(key) unbound in \(manager.submap)")
        guard case let .dispatcher(d) = bind.action else { Issue.record("\(key) is not a dispatcher"); return }
        manager.dispatch(d)
    }

    private func border(_ manager: WindowManager) -> Double { Double(manager.computePlan().frame(of: 2)!.minX) }

    @Test(arguments: ["right", "l"]) func rightWindowRightKeyMovesBorderRight(key: String) throws {
        let (manager, config) = try session()
        manager.markFocused(2)
        let start = border(manager)
        try press(key, manager, config)
        #expect(border(manager) == start + 40)
    }

    @Test(arguments: ["left", "h"]) func rightWindowLeftKeyMovesBorderLeft(key: String) throws {
        let (manager, config) = try session()
        manager.markFocused(2)
        let start = border(manager)
        try press(key, manager, config)
        #expect(border(manager) == start - 40)
    }

    @Test(arguments: [("right", 40.0), ("l", 40.0), ("left", -40.0), ("h", -40.0)])
    func leftWindowKeysStillMoveBorderTheArrowWay(key: String, shift: Double) throws {
        let (manager, config) = try session()
        manager.markFocused(1)
        let start = border(manager)
        try press(key, manager, config)
        #expect(border(manager) == start + shift)
    }

    @Test(arguments: ["master", "even-horizontal"]) func otherLayoutsFollowTheArrowFromTheRightWindow(layout: String) throws {
        let (manager, config) = try session(layout)
        manager.markFocused(2)
        let start = border(manager)
        try press("l", manager, config)
        let afterRight = border(manager)
        try press("h", manager, config); try press("h", manager, config)
        #expect(afterRight > start)
        #expect(border(manager) < start)
    }

    @Test func verticalKeysMoveTheHorizontalBorderTheArrowWay() throws {
        let (manager, config) = try session(windows: 3)
        // dwindle: 1 left, 2 top right, 3 bottom right; focus the bottom one
        manager.markFocused(3)
        let top = { Double(manager.computePlan().frame(of: 3)!.minY) }
        let start = top()
        try press("k", manager, config)
        let up = top()
        try press("j", manager, config); try press("down", manager, config)
        #expect(up == start - 40)
        #expect(top() == start + 40)
    }

    @Test func escapeLeavesResizeModeAndKeysStopResizing() throws {
        let (manager, config) = try session()
        manager.markFocused(2)
        try press("escape", manager, config)
        #expect(manager.submap == "")
        let start = border(manager)
        // h/l outside resize mode are not resize binds
        let combo = try KeyCombo.parse("l").get()
        #expect(config.binds.first { $0.submap == nil && $0.combo == combo } == nil)
        #expect(border(manager) == start)
    }

    @Test func clampsAtTheExtremeWithoutFlipping() throws {
        let (manager, config) = try session()
        manager.markFocused(2)
        var last = border(manager)
        for _ in 0..<40 {
            try press("right", manager, config)
            #expect(border(manager) >= last)
            last = border(manager)
        }
        #expect(last < 1000)
    }
}
