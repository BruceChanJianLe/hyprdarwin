import CoreGraphics
import Testing
@testable import HyprdarwinCore

private let area = CGRect(x: 0, y: 0, width: 1000, height: 500)

@Suite struct DwindleTests {
    @Test func firstWindowFillsArea() {
        var layout = DwindleLayout()
        layout.insert(1, nextTo: nil, area: area, options: DwindleOptions())
        #expect(layout.frames(in: area, options: DwindleOptions()) == [1: area])
    }

    @Test func splitsAlongLongerSideAndRecurses() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.insert(3, nextTo: 2, area: area, options: options)
        let frames = layout.frames(in: area, options: options)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 500))
        // window 2's 500x500 box is split vertically (square -> horizontal first, then 500 wide x 500 high)
        #expect(frames[2] == CGRect(x: 500, y: 0, width: 250, height: 500))
        #expect(frames[3] == CGRect(x: 750, y: 0, width: 250, height: 500))
        #expect(layout.windows == [1, 2, 3])
    }

    @Test func tallBoxesStack() {
        let tall = CGRect(x: 0, y: 0, width: 400, height: 1000)
        var layout = DwindleLayout()
        layout.insert(1, nextTo: nil, area: tall, options: DwindleOptions())
        layout.insert(2, nextTo: 1, area: tall, options: DwindleOptions())
        let frames = layout.frames(in: tall, options: DwindleOptions())
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(frames[2] == CGRect(x: 0, y: 500, width: 400, height: 500))
    }

    @Test func forceSplitAndCursorSide() {
        var options = DwindleOptions()
        options.forceSplit = 1
        var layout = DwindleLayout()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        #expect(layout.windows == [2, 1])

        var cursorLayout = DwindleLayout()
        cursorLayout.insert(1, nextTo: nil, area: area, options: DwindleOptions())
        cursorLayout.insert(2, nextTo: 1, area: area, options: DwindleOptions(), cursor: CGPoint(x: 100, y: 100))
        #expect(cursorLayout.windows == [2, 1])
    }

    @Test func removeCollapsesParent() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        for id: WindowID in 1...3 { layout.insert(id, nextTo: id == 1 ? nil : id - 1, area: area, options: options) }
        layout.remove(2)
        let frames = layout.frames(in: area, options: options)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(frames[3] == CGRect(x: 500, y: 0, width: 500, height: 500))
        layout.remove(1)
        layout.remove(3)
        #expect(layout.windows.isEmpty)
    }

    @Test func toggleSplitPinsDirectionWithoutPreserveSplit() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.toggleSplit(2, area: area, options: options)
        let frames = layout.frames(in: area, options: options)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 250))
        #expect(frames[2] == CGRect(x: 0, y: 250, width: 1000, height: 250))
    }

    @Test func preserveSplitKeepsDirectionWhenAreaChanges() {
        var preserving = DwindleOptions()
        preserving.preserveSplit = true
        var layout = DwindleLayout()
        layout.insert(1, nextTo: nil, area: area, options: preserving)
        layout.insert(2, nextTo: 1, area: area, options: preserving)
        let tall = CGRect(x: 0, y: 0, width: 300, height: 900)
        #expect(layout.frames(in: tall, options: preserving)[2]?.minX == 150)
        // without preserve_split the same tree re-evaluates to a stacked split
        #expect(layout.frames(in: tall, options: DwindleOptions())[2]?.minY == 450)
    }

    @Test func resizeMovesTheNearestEdge() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.resize(1, dx: 100, dy: 0, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.width == 600)
        layout.resize(2, dx: 200, dy: 0, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[2]?.width == 600)
        layout.adjustRatio(1, exact: 1.9)
        #expect(layout.frames(in: area, options: options)[1]?.width == 950)
        layout.adjustRatio(1, delta: 5)
        #expect(layout.frames(in: area, options: options)[1]?.width == 950)
    }


    @Test func moveBorderFollowsTheArrow() {
        let options = DwindleOptions()
        func pair() -> DwindleLayout {
            var layout = DwindleLayout()
            layout.insert(1, nextTo: nil, area: area, options: options)
            layout.insert(2, nextTo: 1, area: area, options: options)
            return layout
        }
        // the right window: right moves its left border right, so it shrinks
        var layout = pair()
        layout.moveBorder(of: 2, .right, by: 100, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[2]?.minX == 600)
        layout.moveBorder(of: 2, .left, by: 200, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[2]?.minX.rounded() == 400)
        // the left window: right grows it, left shrinks it
        layout = pair()
        layout.moveBorder(of: 1, .right, by: 100, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.width == 600)
        layout.moveBorder(of: 1, .left, by: 200, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.width.rounded() == 400)
        // no border across the arrow: nothing moves
        layout.moveBorder(of: 1, .up, by: 100, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.height == 500)

        // stacked: down moves the border down whichever window has focus
        let tall = CGRect(x: 0, y: 0, width: 500, height: 1000)
        var stacked = DwindleLayout()
        stacked.insert(1, nextTo: nil, area: tall, options: options)
        stacked.insert(2, nextTo: 1, area: tall, options: options)
        stacked.moveBorder(of: 2, .down, by: 100, area: tall, options: options)
        #expect(stacked.frames(in: tall, options: options)[2]?.minY == 600)
        stacked.moveBorder(of: 1, .up, by: 200, area: tall, options: options)
        #expect(stacked.frames(in: tall, options: options)[2]?.minY.rounded() == 400)
    }

    @Test func moveBorderPicksTheBorderOnThatSide() {
        // 1 | 2 | 3: 2's left border is the root split, its right border the nested one
        var layout = DwindleLayout()
        let options = DwindleOptions()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.insert(3, nextTo: 2, area: area, options: options)
        layout.moveBorder(of: 2, .left, by: 100, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.maxX == 400)
        layout = DwindleLayout()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.insert(3, nextTo: 2, area: area, options: options)
        layout.moveBorder(of: 2, .right, by: 50, area: area, options: options)
        var frames = layout.frames(in: area, options: options)
        #expect(frames[1]?.width == 500, "the root split stays")
        #expect(frames[3]?.minX == 800)
        // at the right edge, 3's left border moves right
        layout.moveBorder(of: 3, .right, by: 50, area: area, options: options)
        frames = layout.frames(in: area, options: options)
        #expect(frames[3]?.minX == 850)
        // at the left edge, 1's right border moves left
        layout.moveBorder(of: 1, .left, by: 100, area: area, options: options)
        #expect(layout.frames(in: area, options: options)[1]?.width == 400)
    }
    @Test func swapAndSwapSplit() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        layout.insert(1, nextTo: nil, area: area, options: options)
        layout.insert(2, nextTo: 1, area: area, options: options)
        layout.swap(1, 2)
        #expect(layout.windows == [2, 1])
        layout.swapSplit(1)
        #expect(layout.windows == [1, 2])
        layout.replace(2, with: 9)
        #expect(layout.windows == [1, 9])
    }
}

@Suite struct MasterTests {
    @Test func leftOrientation() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...3 { layout.insert(id, focused: nil, options: MasterOptions()) }
        let frames = layout.frames(in: area)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 550, height: 500))
        #expect(frames[2] == CGRect(x: 550, y: 0, width: 450, height: 250))
        #expect(frames[3] == CGRect(x: 550, y: 250, width: 450, height: 250))
    }

    @Test func singleWindowFillsArea() {
        var layout = MasterLayout(options: MasterOptions())
        layout.insert(1, focused: nil, options: MasterOptions())
        #expect(layout.frames(in: area) == [1: area])
    }

    @Test func topAndRightOrientations() {
        var options = MasterOptions()
        options.orientation = .top
        options.mfact = 0.6
        var layout = MasterLayout(options: options)
        for id: WindowID in 1...3 { layout.insert(id, focused: nil, options: options) }
        var frames = layout.frames(in: area)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(frames[2] == CGRect(x: 0, y: 300, width: 500, height: 200))
        #expect(frames[3] == CGRect(x: 500, y: 300, width: 500, height: 200))
        layout.orientation = .right
        frames = layout.frames(in: area)
        #expect(frames[1] == CGRect(x: 400, y: 0, width: 600, height: 500))
    }

    @Test func newStatusMasterAndInherit() {
        var options = MasterOptions()
        options.newStatus = .master
        var layout = MasterLayout(options: options)
        layout.insert(1, focused: nil, options: options)
        layout.insert(2, focused: 1, options: options)
        #expect(layout.windows == [2, 1])

        options.newStatus = .inherit
        layout.insert(3, focused: 1, options: options)
        #expect(layout.windows == [2, 1, 3])
        layout.insert(4, focused: 2, options: options)
        #expect(layout.windows.first == 4)

        var onTop = MasterOptions()
        onTop.newOnTop = true
        var stack = MasterLayout(options: onTop)
        for id: WindowID in 1...3 { stack.insert(id, focused: nil, options: onTop) }
        #expect(stack.windows == [1, 3, 2])
    }

    @Test func swapWithMasterAndMasterCount() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...4 { layout.insert(id, focused: nil, options: MasterOptions()) }
        #expect(layout.swapWithMaster(3) == 3)
        #expect(layout.windows == [3, 2, 1, 4])
        #expect(layout.swapWithMaster(3) == 2)
        #expect(layout.windows == [2, 3, 1, 4])
        layout.addMaster(4)
        #expect(layout.masterCount == 2)
        #expect(layout.windows == [2, 4, 3, 1])
        #expect(layout.isMaster(4))
        let frames = layout.frames(in: area)
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 550, height: 250))
        #expect(frames[4] == CGRect(x: 0, y: 250, width: 550, height: 250))
        layout.removeMaster(2)
        #expect(layout.masterCount == 1)
        #expect(layout.windows == [4, 2, 3, 1])
        layout.remove(4)
        layout.remove(2)
        layout.remove(3)
        #expect(layout.masterCount == 1)
    }

    @Test func mfactAndResize() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...2 { layout.insert(id, focused: nil, options: MasterOptions()) }
        layout.adjustMfact(delta: 0.05)
        #expect(abs(layout.mfact - 0.6) < 1e-9)
        layout.resize(2, dx: 100, dy: 0, area: area)
        #expect(abs(layout.mfact - 0.5) < 1e-9)
        layout.adjustMfact(exact: 2)
        #expect(layout.mfact == 0.95)
    }


    @Test func moveBorderMovesTheBoundaryTheArrowWay() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...2 { layout.insert(id, focused: nil, options: MasterOptions()) }
        // master on the left: right moves the boundary right from either side
        layout.moveBorder(of: 2, .right, by: 100, area: area)
        #expect(abs(layout.mfact - 0.65) < 1e-9)
        layout.moveBorder(of: 1, .right, by: 100, area: area)
        #expect(abs(layout.mfact - 0.75) < 1e-9)
        layout.moveBorder(of: 2, .left, by: 200, area: area)
        #expect(abs(layout.mfact - 0.55) < 1e-9)
        layout.moveBorder(of: 2, .up, by: 100, area: area)
        #expect(abs(layout.mfact - 0.55) < 1e-9, "no border across the arrow")
        // master on the right: right shrinks it
        layout.orientation = .right
        layout.moveBorder(of: 1, .right, by: 100, area: area)
        #expect(abs(layout.mfact - 0.45) < 1e-9)
        // master at the bottom: down shrinks it
        layout.orientation = .bottom
        layout.moveBorder(of: 2, .down, by: 50, area: area)
        #expect(abs(layout.mfact - 0.35) < 1e-9)
    }
    @Test func cycleAndRoll() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...3 { layout.insert(id, focused: nil, options: MasterOptions()) }
        #expect(layout.cycle(from: 3, step: 1) == 1)
        #expect(layout.cycle(from: 1, step: -1) == 3)
        layout.roll(step: 1)
        #expect(layout.windows == [2, 3, 1])
    }
}

@Suite struct WorkspaceLayoutTests {
    @Test func messages() {
        var layout = WorkspaceLayout(kind: .dwindle, options: LayoutOptions())
        layout.insert(1, focused: nil, area: area, options: LayoutOptions(), cursor: nil)
        layout.insert(2, focused: 1, area: area, options: LayoutOptions(), cursor: nil)
        #expect(layout.message("splitratio exact 1.5", focused: 1, area: area, options: LayoutOptions()) == LayoutMessageResult())
        #expect(layout.frames(in: area, options: LayoutOptions())[1]?.width == 750)
        #expect(layout.message("splitratio nope", focused: 1, area: area, options: LayoutOptions()).error != nil)
        #expect(layout.message("orientationtop", focused: 1, area: area, options: LayoutOptions()).error != nil)

        var master = layout.converted(to: .master, area: area, options: LayoutOptions())
        #expect(master.isKind(.master))
        #expect(master.windows == [1, 2])
        #expect(master.message("focusmaster", focused: 2, area: area, options: LayoutOptions()).focus == 1)
        _ = master.message("orientationbottom", focused: 2, area: area, options: LayoutOptions())
        #expect(master.frames(in: area, options: LayoutOptions())[1]?.minY == 225)
        #expect(master.message("cyclenext", focused: 1, area: area, options: LayoutOptions()).focus == 2)
    }

    @Test func gapsBetweenTilesAndNotAtEdges() {
        let raw: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 500),
            2: CGRect(x: 500, y: 0, width: 500, height: 500),
        ]
        let frames = Gaps.apply(raw, area: area, gapsIn: Insets(all: 5))
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 495, height: 500))
        #expect(frames[2] == CGRect(x: 505, y: 0, width: 495, height: 500))
    }
}

@Suite struct MinimumSizeTests {
    @Test func spaceKeepsExactGeometryUntilAMinimumBinds() {
        #expect(Space.distribute(900, weights: [1, 1, 1], minimums: [0, 100, 0]) == nil)
        #expect(Space.distribute(900, weights: [1, 1, 1], minimums: [500, 0, 0]) == [500, 200, 200])
        // the second round fixes a part that the first round's share pushed under its minimum
        #expect(Space.distribute(900, weights: [1, 1, 1], minimums: [500, 250, 0]) == [500, 250, 150])
        #expect(Space.distribute(900, weights: [1, 1], minimums: [600, 600]) == [450, 450], "cannot fit: share by minimums")
        #expect(Space.split(1000, desired: 500, minimums: (0, 700)) == 300)
        #expect(Space.split(1000, desired: 500, minimums: (100, 100)) == 500)
    }

    @Test func dwindleSplitsMakeRoomForAMinimum() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        for id: WindowID in 1...3 { layout.insert(id, nextTo: id == 1 ? nil : id - 1, area: square, options: options) }
        // 1 | (2 / 3)
        let frames = layout.frames(in: square, options: options, minimums: [3: CGSize(width: 800, height: 600)])
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 200, height: 1000))
        #expect(frames[2] == CGRect(x: 200, y: 0, width: 800, height: 400))
        #expect(frames[3] == CGRect(x: 200, y: 400, width: 800, height: 600))
        #expect(layout.minimumSize(in: area, options: options, minimums: [1: CGSize(width: 300, height: 0), 3: CGSize(width: 800, height: 0)])
            == CGSize(width: 1100, height: 0))
    }

    @Test func dwindleSplitsKeepTheDirectionTheirMinimumsWereMeasuredIn() {
        var layout = DwindleLayout()
        let options = DwindleOptions()
        let wide = CGRect(x: 0, y: 0, width: 1488, height: 900)
        for id: WindowID in 1...3 { layout.insert(id, nextTo: id == 1 ? nil : id - 1, area: wide, options: options) }
        // 1 | (2 / 3); a 1000 wide right column would turn 2 / 3 side by side
        let minimums: [WindowID: CGSize] = [2: CGSize(width: 1000, height: 0)]
        let frames = layout.frames(in: wide, options: options, minimums: minimums)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 488, height: 900))
        #expect(frames[2] == CGRect(x: 488, y: 0, width: 1000, height: 450))
        #expect(frames[3] == CGRect(x: 488, y: 450, width: 1000, height: 450))
        #expect(layout.minimumSize(in: wide, options: options, minimums: minimums) == CGSize(width: 1000, height: 0))
    }

    @Test func masterStacksMakeRoomForAMinimum() {
        var layout = MasterLayout(options: MasterOptions())
        for id: WindowID in 1...3 { layout.insert(id, focused: nil, options: MasterOptions()) }
        let frames = layout.frames(in: area, minimums: [2: CGSize(width: 600, height: 400)])
        #expect(frames[1]?.width == 400, "the master column shrinks for the wide slave")
        #expect(frames[2] == CGRect(x: 400, y: 0, width: 600, height: 400))
        #expect(frames[3] == CGRect(x: 400, y: 400, width: 600, height: 100))
    }
}

@Suite struct EvenLayoutTests {
    func layout(_ arrangement: EvenArrangement, _ count: WindowID) -> EvenLayout {
        var layout = EvenLayout(arrangement: arrangement)
        for id in 1...count { layout.insert(id, after: id == 1 ? nil : id - 1) }
        return layout
    }

    @Test func evenHorizontalAndVertical() {
        let h = layout(.horizontal, 4).frames(in: area)
        #expect((1...4).map { h[$0]!.minX } == [0, 250, 500, 750])
        let v = layout(.vertical, 2).frames(in: area)
        #expect(v[2] == CGRect(x: 0, y: 250, width: 1000, height: 250))
    }

    @Test func tiledFollowsTmuxRowsAndColumns() {
        #expect(EvenLayout.grid(count: 2) == (2, 1))
        #expect(EvenLayout.grid(count: 3) == (2, 2))
        #expect(EvenLayout.grid(count: 5) == (3, 2))
        #expect(EvenLayout.grid(count: 7) == (3, 3))
        let five = layout(.tiled, 5).frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(five[1] == CGRect(x: 0, y: 0, width: 500, height: 200))
        #expect(five[4] == CGRect(x: 500, y: 200, width: 500, height: 200))
        #expect(five[5] == CGRect(x: 0, y: 400, width: 1000, height: 200), "a lone last window spans the row")
        let eight = layout(.tiled, 8).frames(in: CGRect(x: 0, y: 0, width: 900, height: 900))
        #expect(eight[7]?.width == 450, "the incomplete last row shares its width evenly")
    }

    @Test func newWindowsGoAfterTheFocusedOne() {
        var even = layout(.horizontal, 3)
        even.insert(9, after: 1)
        #expect(even.windows == [1, 9, 2, 3])
    }

    @Test func resizeShiftsSpaceToTheNeighbour() {
        var even = layout(.horizontal, 2)
        even.resize(1, dx: 100, dy: 0, area: area)
        #expect(even.frames(in: area)[1]?.width == 600)
        even.resize(2, dx: 100, dy: 0, area: area)
        #expect(even.frames(in: area)[2]?.width == 500, "the last window grows into the previous one")
        even.resize(1, dx: 5000, dy: 0, area: area)
        #expect(even.frames(in: area)[2]!.width > 0, "never squeezed to nothing")

        var grid = layout(.tiled, 4)
        grid.resize(1, dx: 0, dy: 100, area: area)
        #expect(grid.frames(in: area)[1]?.height == 350)
        #expect(grid.frames(in: area)[2]?.height == 350, "the whole row grows")
        grid.resize(4, dx: 100, dy: 0, area: area)
        #expect(grid.frames(in: area)[2]?.width == 600, "and whole columns")
    }


    @Test func moveBorderFollowsTheArrow() {
        var even = layout(.horizontal, 3)
        even.moveBorder(of: 2, .left, by: 100, area: area)
        var widths = even.frames(in: area).mapValues { $0.width.rounded() }
        #expect(widths == [1: 233, 2: 433, 3: 333], "2's left border moves left")
        even = layout(.horizontal, 3)
        even.moveBorder(of: 3, .right, by: 100, area: area)
        widths = even.frames(in: area).mapValues { $0.width.rounded() }
        #expect(widths == [1: 333, 2: 433, 3: 233], "at the right edge, 3's left border moves right")
        even = layout(.horizontal, 3)
        even.moveBorder(of: 1, .left, by: 100, area: area)
        widths = even.frames(in: area).mapValues { $0.width.rounded() }
        #expect(widths == [1: 233, 2: 433, 3: 333], "at the left edge, 1's right border moves left")
        even.moveBorder(of: 1, .up, by: 100, area: area)
        #expect(even.frames(in: area).mapValues { $0.width.rounded() } == widths, "no border across the arrow")

        var grid = layout(.tiled, 4)
        grid.moveBorder(of: 4, .down, by: 100, area: area)
        #expect(grid.frames(in: area)[4]?.height == 150, "the bottom row's top border moves down")
        grid.moveBorder(of: 2, .right, by: 100, area: area)
        #expect(grid.frames(in: area)[2]?.width == 400, "the right column's left border moves right")
        grid.moveBorder(of: 1, .right, by: 200, area: area)
        #expect(grid.frames(in: area)[1]?.width == 800)
    }
    @Test func minimumsMoveTheBoundaries() {
        let frames = layout(.horizontal, 3).frames(in: CGRect(x: 0, y: 0, width: 900, height: 500), minimums: [2: CGSize(width: 500, height: 0)])
        #expect(frames.mapValues(\.width) == [1: 200, 2: 500, 3: 200])
        #expect(layout(.tiled, 3).minimumSize(minimums: [1: CGSize(width: 400, height: 300), 3: CGSize(width: 900, height: 100)])
            == CGSize(width: 900, height: 400))
    }
}
