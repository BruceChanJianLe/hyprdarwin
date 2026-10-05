import CoreGraphics
import Foundation

public struct DwindleOptions: Equatable, Sendable {
    /// Keep each split's direction when its box changes shape.
    public var preserveSplit = false
    /// 0: new window goes on the cursor's side (right/bottom without a cursor),
    /// 1: always left/top, 2: always right/bottom.
    public var forceSplit = 0
    /// Hyprland units: 0.1...1.9, 1.0 is an even split.
    public var defaultSplitRatio = 1.0
    /// Width is multiplied by this before comparing with height to pick a direction.
    public var splitWidthMultiplier = 1.0

    public init() {}
}

public enum SplitAxis: String, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical

    var flipped: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// Hyprland's dwindle layout: a binary tree where every new window splits the
/// box of the window it opens next to, along the box's longer side.
public struct DwindleLayout: Equatable, Sendable {
    indirect enum Node: Equatable, Sendable {
        case leaf(WindowID)
        /// `ratio` is in Hyprland units (first child's share * 2). A pinned
        /// split keeps its axis even without preserve_split (set by togglesplit).
        case split(axis: SplitAxis, ratio: Double, pinned: Bool, first: Node, second: Node)
    }

    var root: Node?

    public init() {}

    public static let ratioRange = 0.1...1.9

    /// Windows in tree order (left/top first).
    public var windows: [WindowID] {
        guard let root else { return [] }
        return Self.leaves(root)
    }

    public func contains(_ id: WindowID) -> Bool { root.map { Self.path(to: id, in: $0) != nil } ?? false }

    // MARK: - Mutation

    public mutating func insert(
        _ id: WindowID, nextTo target: WindowID?, area: CGRect,
        options: DwindleOptions, cursor: CGPoint? = nil
    ) {
        guard !contains(id) else { return }
        guard let root else {
            self.root = .leaf(id)
            return
        }
        let targetID = target.flatMap { contains($0) ? $0 : nil } ?? windows.last!
        guard let path = Self.path(to: targetID, in: root) else { return }
        let box = boxes(in: area, options: options).first { $0.path == path }?.box ?? area
        let axis: SplitAxis = box.width * options.splitWidthMultiplier >= box.height ? .horizontal : .vertical

        let newFirst: Bool
        switch options.forceSplit {
        case 1: newFirst = true
        case 2: newFirst = false
        default:
            if let cursor, box.contains(cursor) {
                newFirst = axis == .horizontal ? cursor.x < box.midX : cursor.y < box.midY
            } else {
                newFirst = false
            }
        }
        let ratio = options.defaultSplitRatio.clamped(to: Self.ratioRange)
        let split = Node.split(
            axis: axis, ratio: ratio, pinned: false,
            first: newFirst ? .leaf(id) : .leaf(targetID),
            second: newFirst ? .leaf(targetID) : .leaf(id)
        )
        self.root = Self.replacing(at: path, in: root, with: split)
    }

    public mutating func remove(_ id: WindowID) {
        guard let root else { return }
        self.root = Self.removing(id, from: root)
    }

    /// Exchange two windows' places in the tree.
    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let root, a != b, contains(a), contains(b) else { return }
        self.root = Self.mapLeaves(root) { $0 == a ? b : ($0 == b ? a : $0) }
    }

    /// Replace `old` with `new` in place (used when a window moves between layouts).
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let root, contains(old), !contains(new) else { return }
        self.root = Self.mapLeaves(root) { $0 == old ? new : $0 }
    }

    /// Flip the direction of the split that holds `id`.
    public mutating func toggleSplit(_ id: WindowID, area: CGRect, options: DwindleOptions) {
        guard let root, let path = Self.path(to: id, in: root), !path.isEmpty else { return }
        let parentPath = Array(path.dropLast())
        let effective = boxes(in: area, options: options).first { $0.path == parentPath }?.axis
        self.root = Self.modifying(at: parentPath, in: root) { node in
            guard case let .split(axis, ratio, _, first, second) = node else { return node }
            return .split(axis: (effective ?? axis).flipped, ratio: ratio, pinned: true, first: first, second: second)
        }
    }

    /// Swap the two halves of the split that holds `id`.
    public mutating func swapSplit(_ id: WindowID) {
        guard let root, let path = Self.path(to: id, in: root), !path.isEmpty else { return }
        self.root = Self.modifying(at: Array(path.dropLast()), in: root) { node in
            guard case let .split(axis, ratio, pinned, first, second) = node else { return node }
            return .split(axis: axis, ratio: 2 - ratio, pinned: pinned, first: second, second: first)
        }
    }

    /// Change the ratio of the split that holds `id`: by `delta`, or to `exact`.
    public mutating func adjustRatio(_ id: WindowID, delta: Double? = nil, exact: Double? = nil) {
        guard let root, let path = Self.path(to: id, in: root), !path.isEmpty else { return }
        self.root = Self.modifying(at: Array(path.dropLast()), in: root) { node in
            guard case let .split(axis, ratio, pinned, first, second) = node else { return node }
            let next = (exact ?? (ratio + (delta ?? 0))).clamped(to: Self.ratioRange)
            return .split(axis: axis, ratio: next, pinned: pinned, first: first, second: second)
        }
    }

    /// Grow or shrink `id` by moving the nearest edge on each axis
    /// (positive values grow the window).
    public mutating func resize(_ id: WindowID, dx: Double, dy: Double, area: CGRect, options: DwindleOptions) {
        guard let root, let path = Self.path(to: id, in: root) else { return }
        let all = boxes(in: area, options: options)
        var updated = root
        for (delta, axis) in [(dx, SplitAxis.horizontal), (dy, SplitAxis.vertical)] where delta != 0 {
            // deepest ancestor split along this axis
            for depth in stride(from: path.count - 1, through: 0, by: -1) {
                let ancestor = Array(path.prefix(depth))
                guard let entry = all.first(where: { $0.path == ancestor }), entry.axis == axis else { continue }
                let inFirst = !path[depth]
                let size = axis == .horizontal ? entry.box.width : entry.box.height
                guard size > 0 else { break }
                let change = delta / size * 2 * (inFirst ? 1 : -1)
                updated = Self.modifying(at: ancestor, in: updated) { node in
                    guard case let .split(splitAxis, ratio, pinned, first, second) = node else { return node }
                    return .split(
                        axis: splitAxis, ratio: (ratio + change).clamped(to: Self.ratioRange),
                        pinned: pinned, first: first, second: second
                    )
                }
                break
            }
        }
        self.root = updated
    }

    // MARK: - Geometry

    struct BoxEntry {
        var path: [Bool]
        var box: CGRect
        /// Effective axis for splits, nil for leaves.
        var axis: SplitAxis?
        var window: WindowID?
    }

    /// Every node's box. `minimums` (per window, gaps included) move a
    /// split away from the even ratio so each side gets at least what its
    /// windows need, as long as both sides fit. Splits then keep the
    /// direction they have without minimums, the one their minimums were
    /// measured in.
    func boxes(in area: CGRect, options: DwindleOptions, minimums: [WindowID: CGSize] = [:]) -> [BoxEntry] {
        guard let root else { return [] }
        let axes = minimums.isEmpty ? [:] : splitAxes(in: area, options: options)
        var result: [BoxEntry] = []
        func walk(_ node: Node, _ box: CGRect, _ path: [Bool]) {
            switch node {
            case .leaf(let id):
                result.append(BoxEntry(path: path, box: box, axis: nil, window: id))
            case let .split(storedAxis, ratio, pinned, first, second):
                let axis = axes[path] ?? Self.axis(storedAxis, pinned: pinned, box: box, options: options)
                result.append(BoxEntry(path: path, box: box, axis: axis, window: nil))
                let horizontal = axis == .horizontal
                let total = horizontal ? box.width : box.height
                var length = total * ratio / 2
                if !minimums.isEmpty {
                    let minA = Self.minimum(of: first, at: path + [false], axes: axes, minimums: minimums)
                    let minB = Self.minimum(of: second, at: path + [true], axes: axes, minimums: minimums)
                    length = Space.split(total, desired: length, minimums: horizontal ? (minA.width, minB.width) : (minA.height, minB.height))
                }
                let (a, b) = Self.cut(box, axis: axis, first: length)
                walk(first, a, path + [false])
                walk(second, b, path + [true])
            }
        }
        walk(root, area, [])
        return result
    }

    static func axis(_ stored: SplitAxis, pinned: Bool, box: CGRect, options: DwindleOptions) -> SplitAxis {
        if options.preserveSplit || pinned { return stored }
        return box.width * options.splitWidthMultiplier >= box.height ? .horizontal : .vertical
    }

    static func cut(_ box: CGRect, axis: SplitAxis, first length: Double) -> (CGRect, CGRect) {
        if axis == .horizontal {
            return (CGRect(x: box.minX, y: box.minY, width: length, height: box.height),
                    CGRect(x: box.minX + length, y: box.minY, width: box.width - length, height: box.height))
        }
        return (CGRect(x: box.minX, y: box.minY, width: box.width, height: length),
                CGRect(x: box.minX, y: box.minY + length, width: box.width, height: box.height - length))
    }

    /// Each split's direction (by path) at its plain ratios.
    func splitAxes(in area: CGRect, options: DwindleOptions) -> [[Bool]: SplitAxis] {
        var axes: [[Bool]: SplitAxis] = [:]
        for entry in boxes(in: area, options: options) {
            if let axis = entry.axis { axes[entry.path] = axis }
        }
        return axes
    }

    /// The smallest box the windows of `node` (at `path`) fit in, with the
    /// splits along `axes`: side by side widths add up, stacked heights add up.
    static func minimum(of node: Node, at path: [Bool], axes: [[Bool]: SplitAxis], minimums: [WindowID: CGSize]) -> CGSize {
        switch node {
        case .leaf(let id):
            return minimums[id] ?? .zero
        case let .split(storedAxis, _, _, first, second):
            let minA = minimum(of: first, at: path + [false], axes: axes, minimums: minimums)
            let minB = minimum(of: second, at: path + [true], axes: axes, minimums: minimums)
            if (axes[path] ?? storedAxis) == .horizontal {
                return CGSize(width: minA.width + minB.width, height: max(minA.height, minB.height))
            }
            return CGSize(width: max(minA.width, minB.width), height: minA.height + minB.height)
        }
    }

    /// The smallest area every window fits in at its minimum.
    public func minimumSize(in area: CGRect, options: DwindleOptions, minimums: [WindowID: CGSize]) -> CGSize {
        root.map { Self.minimum(of: $0, at: [], axes: splitAxes(in: area, options: options), minimums: minimums) } ?? .zero
    }

    /// Raw tile boxes (no gaps) covering `area`.
    public func frames(in area: CGRect, options: DwindleOptions, minimums: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        var result: [WindowID: CGRect] = [:]
        for entry in boxes(in: area, options: options, minimums: minimums) {
            if let window = entry.window { result[window] = entry.box }
        }
        return result
    }

    // MARK: - Tree helpers

    static func leaves(_ node: Node) -> [WindowID] {
        switch node {
        case .leaf(let id): return [id]
        case let .split(_, _, _, first, second): return leaves(first) + leaves(second)
        }
    }

    static func path(to id: WindowID, in node: Node) -> [Bool]? {
        switch node {
        case .leaf(let leaf): return leaf == id ? [] : nil
        case let .split(_, _, _, first, second):
            if let path = path(to: id, in: first) { return [false] + path }
            if let path = path(to: id, in: second) { return [true] + path }
            return nil
        }
    }

    static func modifying(at path: [Bool], in node: Node, _ transform: (Node) -> Node) -> Node {
        guard let step = path.first else { return transform(node) }
        guard case let .split(axis, ratio, pinned, first, second) = node else { return node }
        let rest = Array(path.dropFirst())
        if step {
            return .split(axis: axis, ratio: ratio, pinned: pinned, first: first, second: modifying(at: rest, in: second, transform))
        }
        return .split(axis: axis, ratio: ratio, pinned: pinned, first: modifying(at: rest, in: first, transform), second: second)
    }

    static func replacing(at path: [Bool], in node: Node, with replacement: Node) -> Node {
        modifying(at: path, in: node) { _ in replacement }
    }

    static func removing(_ id: WindowID, from node: Node) -> Node? {
        switch node {
        case .leaf(let leaf):
            return leaf == id ? nil : node
        case let .split(axis, ratio, pinned, first, second):
            let a = removing(id, from: first)
            let b = removing(id, from: second)
            switch (a, b) {
            case let (a?, b?): return .split(axis: axis, ratio: ratio, pinned: pinned, first: a, second: b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }
    }

    static func mapLeaves(_ node: Node, _ transform: (WindowID) -> WindowID) -> Node {
        switch node {
        case .leaf(let id): return .leaf(transform(id))
        case let .split(axis, ratio, pinned, first, second):
            return .split(axis: axis, ratio: ratio, pinned: pinned, first: mapLeaves(first, transform), second: mapLeaves(second, transform))
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
