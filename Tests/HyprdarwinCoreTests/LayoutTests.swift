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
        #expect(master.kind == .master)
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
