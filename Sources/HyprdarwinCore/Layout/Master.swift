import CoreGraphics
import Foundation

public enum MasterOrientation: String, Sendable, CaseIterable {
    case left, top, right, bottom

    func next(_ step: Int) -> MasterOrientation {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[((index + step) % all.count + all.count) % all.count]
    }
}

public enum MasterNewStatus: String, Sendable {
    case master, slave, inherit
}

public struct MasterOptions: Equatable, Sendable {
    /// Share of the area given to the master stack, 0.05...0.95.
    public var mfact = 0.55
    public var newStatus = MasterNewStatus.slave
    /// New slaves go to the top of the slave stack instead of the bottom.
    public var newOnTop = false
    public var orientation = MasterOrientation.left

    public init() {}
}

/// Hyprland's master layout: one or more masters in a stack taking `mfact`
/// of the area on the `orientation` side, everything else stacked beside it.
public struct MasterLayout: Equatable, Sendable {
    /// Masters first, then slaves.
    public private(set) var windows: [WindowID] = []
    public private(set) var masterCount = 1
    public var mfact: Double
    public var orientation: MasterOrientation

    public static let mfactRange = 0.05...0.95

    public init(options: MasterOptions) {
        mfact = options.mfact.clamped(to: Self.mfactRange)
        orientation = options.orientation
    }

    public func contains(_ id: WindowID) -> Bool { windows.contains(id) }

    public func isMaster(_ id: WindowID) -> Bool {
        guard let index = windows.firstIndex(of: id) else { return false }
        return index < effectiveMasterCount
    }

    var effectiveMasterCount: Int { min(max(1, masterCount), max(1, windows.count)) }

    // MARK: - Mutation

    public mutating func insert(_ id: WindowID, focused: WindowID?, options: MasterOptions) {
        guard !contains(id) else { return }
        guard !windows.isEmpty else {
            windows = [id]
            return
        }
        let asMaster: Bool
        switch options.newStatus {
        case .master: asMaster = true
        case .slave: asMaster = false
        case .inherit: asMaster = focused.map(isMaster) ?? false
        }
        if asMaster {
            windows.insert(id, at: 0)
        } else if options.newOnTop {
            windows.insert(id, at: min(effectiveMasterCount, windows.count))
        } else {
            windows.append(id)
        }
    }

    public mutating func remove(_ id: WindowID) {
        guard let index = windows.firstIndex(of: id) else { return }
        windows.remove(at: index)
        masterCount = max(1, min(masterCount, max(1, windows.count)))
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let i = windows.firstIndex(of: a), let j = windows.firstIndex(of: b) else { return }
        windows.swapAt(i, j)
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let index = windows.firstIndex(of: old), !contains(new) else { return }
        windows[index] = new
    }

    /// Focused master swaps with the first slave; a slave swaps with the first master.
    @discardableResult
    public mutating func swapWithMaster(_ id: WindowID) -> WindowID? {
        guard let index = windows.firstIndex(of: id), windows.count > 1 else { return nil }
        if index == 0 {
            windows.swapAt(0, min(effectiveMasterCount, windows.count - 1))
            return windows[0]
        }
        windows.swapAt(0, index)
        return id
    }

    /// Promote the focused slave into the master stack.
    public mutating func addMaster(_ id: WindowID?) {
        guard windows.count > effectiveMasterCount else { return }
        if let id, let index = windows.firstIndex(of: id), index >= effectiveMasterCount {
            windows.remove(at: index)
            windows.insert(id, at: effectiveMasterCount)
        }
        masterCount = effectiveMasterCount + 1
    }

    /// Demote the focused master into the slave stack.
    public mutating func removeMaster(_ id: WindowID?) {
        guard effectiveMasterCount > 1 else { return }
        if let id, let index = windows.firstIndex(of: id), index < effectiveMasterCount {
            windows.remove(at: index)
            windows.insert(id, at: effectiveMasterCount - 1)
        }
        masterCount = effectiveMasterCount - 1
    }

    public mutating func adjustMfact(delta: Double? = nil, exact: Double? = nil) {
        mfact = (exact ?? (mfact + (delta ?? 0))).clamped(to: Self.mfactRange)
    }

    /// Positive dx/dy grows `id`, moving the master/slave boundary.
    public mutating func resize(_ id: WindowID, dx: Double, dy: Double, area: CGRect) {
        guard windows.count > effectiveMasterCount else { return }
        let master = isMaster(id)
        let delta: Double
        switch orientation {
        case .left, .right: delta = dx / max(1, area.width)
        case .top, .bottom: delta = dy / max(1, area.height)
        }
        adjustMfact(delta: master ? delta : -delta)
    }

    /// Move the master/slave boundary `points` in `direction`, whichever
    /// side of it `id` is on (it is the only border across the stacks).
    public mutating func moveBorder(of id: WindowID, _ direction: Direction, by points: Double, area: CGRect) {
        guard contains(id), windows.count > effectiveMasterCount else { return }
        let forward = direction.isIncreasing
        let delta: Double
        switch orientation {
        case .left, .right:
            guard direction.isHorizontal else { return }
            delta = points / max(1, area.width)
        case .top, .bottom:
            guard !direction.isHorizontal else { return }
            delta = points / max(1, area.height)
        }
        // the master grows when the boundary moves away from its side
        let masterFirst = orientation == .left || orientation == .top
        adjustMfact(delta: forward == masterFirst ? delta : -delta)
    }

    /// The window `step` places away in stack order, wrapping around.
    public func cycle(from id: WindowID?, step: Int) -> WindowID? {
        guard !windows.isEmpty else { return nil }
        guard let id, let index = windows.firstIndex(of: id) else { return windows.first }
        return windows[((index + step) % windows.count + windows.count) % windows.count]
    }

    public mutating func swapInStack(_ id: WindowID, step: Int) -> WindowID? {
        guard let other = cycle(from: id, step: step), other != id else { return nil }
        swap(id, other)
        return id
    }

    /// Rotate the whole stack by one place.
    public mutating func roll(step: Int) {
        guard windows.count > 1 else { return }
        if step > 0 {
            windows.append(windows.removeFirst())
        } else {
            windows.insert(windows.removeLast(), at: 0)
        }
    }

    // MARK: - Geometry

    /// Raw tile boxes covering `area`. `minimums` (per window, gaps
    /// included) move the master/stack boundary and the boundaries inside
    /// each stack so every window gets at least its minimum while they fit.
    public func frames(in area: CGRect, minimums: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        guard !windows.isEmpty else { return [:] }
        let masters = Array(windows.prefix(effectiveMasterCount))
        let slaves = Array(windows.dropFirst(effectiveMasterCount))
        // left/right stacks run top to bottom; top/bottom stacks run left to right
        let stackVertically = orientation == .left || orientation == .right
        var masterArea = area
        var slaveArea = CGRect.zero
        if !slaves.isEmpty {
            let total = stackVertically ? area.width : area.height
            var length = total * mfact
            if !minimums.isEmpty {
                let across = { (ids: [WindowID]) in Self.minimum(of: ids, minimums: minimums, vertical: stackVertically) }
                let master = across(masters), slave = across(slaves)
                length = Space.split(total, desired: length, minimums: stackVertically ? (master.width, slave.width) : (master.height, slave.height))
            }
            switch orientation {
            case .left:
                masterArea = CGRect(x: area.minX, y: area.minY, width: length, height: area.height)
                slaveArea = CGRect(x: masterArea.maxX, y: area.minY, width: area.width - length, height: area.height)
            case .right:
                masterArea = CGRect(x: area.maxX - length, y: area.minY, width: length, height: area.height)
                slaveArea = CGRect(x: area.minX, y: area.minY, width: area.width - length, height: area.height)
            case .top:
                masterArea = CGRect(x: area.minX, y: area.minY, width: area.width, height: length)
                slaveArea = CGRect(x: area.minX, y: masterArea.maxY, width: area.width, height: area.height - length)
            case .bottom:
                masterArea = CGRect(x: area.minX, y: area.maxY - length, width: area.width, height: length)
                slaveArea = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - length)
            }
        }
        var result: [WindowID: CGRect] = [:]
        for (ids, box) in [(masters, masterArea), (slaves, slaveArea)] {
            for (id, frame) in zip(ids, Self.stack(box, windows: ids, vertical: stackVertically, minimums: minimums)) {
                result[id] = frame
            }
        }
        return result
    }

    /// The smallest area every window fits in at its minimum.
    public func minimumSize(minimums: [WindowID: CGSize]) -> CGSize {
        let vertical = orientation == .left || orientation == .right
        let master = Self.minimum(of: Array(windows.prefix(effectiveMasterCount)), minimums: minimums, vertical: vertical)
        let slave = Self.minimum(of: Array(windows.dropFirst(effectiveMasterCount)), minimums: minimums, vertical: vertical)
        if vertical {
            return CGSize(width: master.width + slave.width, height: max(master.height, slave.height))
        }
        return CGSize(width: max(master.width, slave.width), height: master.height + slave.height)
    }

    /// A stack's minimum: lengths add up along it, the widest decides across.
    static func minimum(of ids: [WindowID], minimums: [WindowID: CGSize], vertical: Bool) -> CGSize {
        let sizes = ids.map { minimums[$0] ?? .zero }
        if vertical {
            return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height })
        }
        return CGSize(width: sizes.reduce(0) { $0 + $1.width }, height: sizes.map(\.height).max() ?? 0)
    }

    static func stack(_ area: CGRect, windows ids: [WindowID], vertical: Bool, minimums: [WindowID: CGSize]) -> [CGRect] {
        let count = ids.count
        guard count > 0 else { return [] }
        let needed = ids.map { id -> Double in vertical ? minimums[id]?.height ?? 0 : minimums[id]?.width ?? 0 }
        if let lengths = Space.distribute(vertical ? area.height : area.width, weights: Array(repeating: 1, count: count), minimums: needed) {
            return Space.slices(area, lengths: lengths, vertical: vertical)
        }
        return (0..<count).map { index in
            if vertical {
                let h = area.height / Double(count)
                return CGRect(x: area.minX, y: area.minY + h * Double(index), width: area.width, height: h)
            }
            let w = area.width / Double(count)
            return CGRect(x: area.minX + w * Double(index), y: area.minY, width: w, height: area.height)
        }
    }
}
