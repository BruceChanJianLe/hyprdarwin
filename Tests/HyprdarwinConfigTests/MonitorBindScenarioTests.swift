import Foundation
import Testing
@testable import HyprdarwinConfig
@testable import HyprdarwinCore

/// The default config's monitor binds, end to end through the Lua runtime and
/// the model: two displays side by side, press HYPR + ALT (+ SHIFT) + a key.
@Suite struct MonitorBindScenarioTests {
    private static let left = Monitor(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    private static let right = Monitor(id: 2, name: "DELL", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
                                       visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800))

    private func session() throws -> (WindowManager, Config) {
        let config = try #require(ConfigLoader.load(source: DefaultConfig.text, directory: NSTemporaryDirectory()).config)
        let manager = WindowManager(config: config)
        manager.setMonitors([Self.left, Self.right])
        manager.addWindow(WindowInfo(id: 1, pid: 101, bundleID: "com.example.app", appName: "App", title: "W1",
                                     subrole: "AXStandardWindow", frame: CGRect(x: 100, y: 100, width: 400, height: 300),
                                     isResizable: true), isNew: true)
        manager.markFocused(1)
        return (manager, config)
    }

    private func press(_ keys: String, _ manager: WindowManager, _ config: Config) throws {
        let combo = try KeyCombo.parse(keys).get()
        let bind = try #require(config.binds.first { $0.submap == nil && $0.combo == combo }, "\(keys) unbound")
        guard case let .dispatcher(d) = bind.action else { Issue.record("\(keys) is not a dispatcher"); return }
        _ = manager.dispatch(d)
    }

    private func monitorOfWindow(_ manager: WindowManager) -> MonitorID? {
        manager.windows[1].flatMap { manager.workspaces[$0.workspace]?.monitorID }
    }

    @Test(arguments: ["l", "right"]) func altMovesTheWindowToTheRightMonitorAndBack(key: String) throws {
        let (manager, config) = try session()
        #expect(monitorOfWindow(manager) == 1)
        try press("HYPR + ALT + \(key)", manager, config)
        #expect(monitorOfWindow(manager) == 2)
        #expect(manager.focusedMonitorID == 2, "follows the window")
        #expect(manager.computePlan().frame(of: 1).map { $0.minX >= 1000 } == true, "tiled on the right display")
        try press(key == "l" ? "HYPR + ALT + h" : "HYPR + ALT + left", manager, config)
        #expect(monitorOfWindow(manager) == 1)
    }

    @Test(arguments: ["l", "right"]) func altShiftFocusesTheMonitorWithoutMovingTheWindow(key: String) throws {
        let (manager, config) = try session()
        try press("HYPR + ALT + SHIFT + \(key)", manager, config)
        #expect(manager.focusedMonitorID == 2)
        #expect(monitorOfWindow(manager) == 1, "window stays put")
        try press(key == "l" ? "HYPR + ALT + SHIFT + h" : "HYPR + ALT + SHIFT + left", manager, config)
        #expect(manager.focusedMonitorID == 1)
        #expect(manager.focusedWindow == 1)
    }

    @Test(arguments: ["j", "k", "down", "up"]) func noMonitorThatWayIsANoOp(key: String) throws {
        let (manager, config) = try session()
        try press("HYPR + ALT + \(key)", manager, config)
        try press("HYPR + ALT + SHIFT + \(key)", manager, config)
        #expect(monitorOfWindow(manager) == 1)
        #expect(manager.focusedMonitorID == 1)
    }

    /// Every bound combo fires all its binds, so no two binds may share one,
    /// with the shipped mod or the suggested swap.
    @Test(arguments: ["HYPR", "CMD"]) func noTwoBindsShareACombo(mod: String) throws {
        let source = DefaultConfig.text.replacingOccurrences(of: "local mod = \"HYPR\"", with: "local mod = \"\(mod)\"")
        #expect(source.contains("local mod = \"\(mod)\""))
        let config = try #require(ConfigLoader.load(source: source, directory: NSTemporaryDirectory()).config)
        var seen: [String: Int] = [:]
        for bind in config.binds { seen["\(bind.submap ?? "") \(bind.combo)", default: 0] += 1 }
        #expect(seen.filter { $0.value > 1 }.isEmpty, "\(seen.filter { $0.value > 1 })")
    }
}
