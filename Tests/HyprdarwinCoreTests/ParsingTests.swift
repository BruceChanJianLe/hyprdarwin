import CoreGraphics
import Testing
@testable import HyprdarwinCore

@Suite struct KeyComboTests {
    @Test func parsesModifiersAndKeys() throws {
        let combo = try KeyCombo.parse("HYPR + SHIFT + left").get()
        #expect(combo.modifiers == [.hypr, .shift])
        #expect(combo.keyCode == 0x7B)

        let terminal = try KeyCombo.parse("SUPER + Return").get()
        #expect(terminal.modifiers == [.command])
        #expect(terminal.keyCode == 0x24)

        let spaced = try KeyCombo.parse("CTRL ALT code:36").get()
        #expect(spaced.modifiers == [.control, .option])
        #expect(spaced.keyCode == 36)

        #expect(try KeyCombo.parse("escape").get().modifiers.isEmpty)
        #expect(try KeyCombo.parse("HYPR + 0").get().keyCode == 0x1D)
        #expect(try KeyCombo.parse("HYPR + F18").get().keyCode == KeyCodes.f18)
        #expect(try KeyCombo.parse("CMD + bracketright").get().keyCode == 0x1E)
    }

    @Test func rejectsBadCombos() {
        #expect(throws: KeyCombo.ParseError.unknownKey("Hyper")) { try KeyCombo.parse("Hyper + Q").get() }
        #expect(throws: KeyCombo.ParseError.missingKey) { try KeyCombo.parse("HYPR + SHIFT").get() }
        #expect(throws: KeyCombo.ParseError.multipleKeys("Q", "W")) { try KeyCombo.parse("HYPR + Q + W").get() }
        #expect(throws: KeyCombo.ParseError.empty) { try KeyCombo.parse("  ").get() }
    }
}

@Suite struct SelectorTests {
    @Test func workspaceIDs() {
        #expect(WorkspaceID(parsing: "3") == .numbered(3))
        #expect(WorkspaceID(parsing: "42") == .numbered(42))
        #expect(WorkspaceID(parsing: "special") == .special("special"))
        #expect(WorkspaceID(parsing: "special:scratch") == .special("scratch"))
        #expect(WorkspaceID(parsing: "0") == nil)
        #expect(WorkspaceID(parsing: "name:web") == nil)
        #expect(WorkspaceID.special("x").description == "special:x")
    }

    @Test func workspaceSelectors() {
        #expect(WorkspaceSelector(parsing: "e+1") == .existing(1))
        #expect(WorkspaceSelector(parsing: "e-2") == .existing(-2))
        #expect(WorkspaceSelector(parsing: "m+1") == .existingOnMonitor(1))
        #expect(WorkspaceSelector(parsing: "+1") == .relative(1))
        #expect(WorkspaceSelector(parsing: "r-1") == .relative(-1))
        #expect(WorkspaceSelector(parsing: "previous") == .previous)
        #expect(WorkspaceSelector(parsing: "empty") == .empty)
        #expect(WorkspaceSelector(parsing: "7") == .id(.numbered(7)))
        #expect(WorkspaceSelector(parsing: "w[tv1]") == nil)
    }

    @Test func monitorSelectors() {
        #expect(MonitorSelector(parsing: "l") == .direction(.left))
        #expect(MonitorSelector(parsing: "+1") == .relative(1))
        #expect(MonitorSelector(parsing: "1") == .index(1))
        #expect(MonitorSelector(parsing: "current") == .current)
        #expect(MonitorSelector(parsing: "DELL U3423WE") == .name("DELL U3423WE"))
    }

    @Test func colours() {
        let colour = Color(parsing: "rgba(33ccffee)")
        #expect(colour == Color(red: 0x33 / 255, green: 0xcc / 255, blue: 1, alpha: 0xee / 255))
        #expect(Color(parsing: "rgb(000000)")?.alpha == 1)
        #expect(Color(parsing: "0xff00ff00") == Color(red: 0, green: 1, blue: 0, alpha: 1))
        #expect(Color(parsing: "blue") == nil)
    }

    @Test func insetsShorthand() {
        #expect(Insets(css: [1, 2]) == Insets(top: 1, right: 2, bottom: 1, left: 2))
        #expect(Insets(css: [1, 2, 3]) == Insets(top: 1, right: 2, bottom: 3, left: 2))
        #expect(Insets(css: []) == nil)
    }
}

@Suite struct ExpressionTests {
    let vars = RuleExpression.Variables(monitorW: 1920, monitorH: 1080, windowW: 480, windowH: 270, cursorX: 10, cursorY: 20)

    func eval(_ text: String, horizontal: Bool = true) -> Double? {
        try? RuleExpression.evaluate(text, horizontal: horizontal, variables: vars).get()
    }

    @Test func arithmeticAndVariables() {
        #expect(eval("monitor_w-500") == 1420)
        #expect(eval("(monitor_w - window_w) / 2") == 720)
        #expect(eval("50%") == 960)
        #expect(eval("50%", horizontal: false) == 540)
        #expect(eval("-10 + 2*3") == -4)
        #expect(eval("cursor_y", horizontal: false) == 20)
        #expect(eval("1/0") == nil)
        #expect(eval("monitor_x") == nil)
        #expect(eval("10 +") == nil)
    }

    @Test func pairs() {
        #expect(RuleExpression.splitPair("480 270")! == ("480", "270"))
        #expect(RuleExpression.splitPair("monitor_w-500 40")! == ("monitor_w-500", "40"))
        #expect(RuleExpression.splitPair("(monitor_w - window_w) / 2 monitor_h * 0.1")! == ("(monitor_w-window_w)/2", "monitor_h*0.1"))
        #expect(RuleExpression.splitPair("1 2 3") == nil)
        #expect(RuleExpression.validatePair("50% 50%") == nil)
        #expect(RuleExpression.validatePair("50%") != nil)
    }
}

@Suite struct NeighborTests {
    let tiles: [(id: Int, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 500, height: 1000)),
        (2, CGRect(x: 500, y: 0, width: 500, height: 500)),
        (3, CGRect(x: 500, y: 500, width: 500, height: 500)),
    ]

    @Test func findsAdjacentTiles() {
        let origin = tiles[0].frame
        let rest = Array(tiles.dropFirst())
        #expect(Neighbor.find(from: origin, direction: .right, among: rest) == 2)
        #expect(Neighbor.find(from: origin, direction: .left, among: rest) == nil)
        #expect(Neighbor.find(from: tiles[2].frame, direction: .up, among: [tiles[0], tiles[1]]) == 2)
        #expect(Neighbor.find(from: tiles[2].frame, direction: .left, among: [tiles[0], tiles[1]]) == 1)
    }
}
