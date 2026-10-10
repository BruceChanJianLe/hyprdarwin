import CoreGraphics
import Foundation

public enum EvenArrangement: Equatable, Sendable {
    /// tmux even-horizontal: side by side.
    case horizontal
    /// tmux even-vertical: stacked.
    case vertical
    /// tmux tiled: rows of columns, as square as possible.
    case tiled
}

/// tmux's even-horizontal, even-vertical and tiled layouts, kept live: the
/// windows (in order) always share the area evenly, whatever opens or
/// closes. Resizing shifts weight between neighbours: windows in a row or
/// column, or whole rows and columns of the grid.
public struct EvenLayout: Equatable, Sendable {
    public private(set) var windows: [WindowID] = []
    public let arrangement: EvenArrangement
    /// even-horizontal / even-vertical: each window's share (1 is even).
    private var weights: [WindowID: Double] = [:]
    /// tiled: row and column shares, for the grid shape they were set on.
    private var rowWeights: [Double] = []
    private var columnWeights: [Double] = []

    public init(arrangement: EvenArrangement) {
        self.arrangement = arrangement
    }

    public func contains(_ id: WindowID) -> Bool { windows.contains(id) }

    // MARK: - Mutation

    /// New windows go after the focused one (tmux puts a new pane next to the active one).
    public mutating func insert(_ id: WindowID, after focused: WindowID?) {
        guard !contains(id) else { return }
        if let focused, let index = windows.firstIndex(of: focused) {
            windows.insert(id, at: index + 1)
        } else {
            windows.append(id)
        }
    }

    public mutating func remove(_ id: WindowID) {
        guard let index = windows.firstIndex(of: id) else { return }
        windows.remove(at: index)
        weights[id] = nil
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let i = windows.firstIndex(of: a), let j = windows.firstIndex(of: b) else { return }
        windows.swapAt(i, j)
        (weights[a], weights[b]) = (weights[b], weights[a])
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let index = windows.firstIndex(of: old), !contains(new) else { return }
        windows[index] = new
        weights[new] = weights.removeValue(forKey: old)
    }

    /// Grow `id` by dx/dy points, taking the space from its neighbour (the
    /// next one, or the previous one for the last).
    public mutating func resize(_ id: WindowID, dx: Double, dy: Double, area: CGRect) {
        guard let index = windows.firstIndex(of: id), windows.count > 1 else { return }
        switch arrangement {
        case .horizontal, .vertical:
            let delta = arrangement == .horizontal ? dx : dy
            let length = arrangement == .horizontal ? area.width : area.height
            guard delta != 0, length > 0 else { return }
            let neighbour = windows[index == windows.count - 1 ? index - 1 : index + 1]
            var shares = windows.map { weights[$0] ?? 1 }
            Self.shift(&shares, from: windows.firstIndex(of: neighbour)!, to: index, points: delta, length: length)
            for (window, share) in zip(windows, shares) { weights[window] = share }
        case .tiled:
            let grid = Self.grid(count: windows.count)
            let row = index / grid.columns
            let column = index % grid.columns
            if dy != 0, grid.rows > 1, area.height > 0 {
                var rows = currentRowWeights(grid)
                Self.shift(&rows, from: row == grid.rows - 1 ? row - 1 : row + 1, to: row, points: dy, length: area.height)
                rowWeights = rows
            }
            // the incomplete last row spreads evenly; full rows share the columns
            let full = row < grid.rows - 1 || windows.count % grid.columns == 0
            if dx != 0, full, grid.columns > 1, area.width > 0 {
                var columns = currentColumnWeights(grid)
                Self.shift(&columns, from: column == grid.columns - 1 ? column - 1 : column + 1, to: column, points: dx, length: area.width)
                columnWeights = columns
            }
        }
    }

    /// Move the border of `id` (or of its row or column) on the `direction`
    /// side `points` that way; the last one moves its border with the
    /// previous one, the first its border with the next.
    public mutating func moveBorder(of id: WindowID, _ direction: Direction, by points: Double, area: CGRect) {
        guard let index = windows.firstIndex(of: id), windows.count > 1, points != 0 else { return }
        let forward = direction.isIncreasing
        // the border between shares `before` and `before + 1` moves forward or back
        func move(_ shares: inout [Double], at position: Int, length: Double) {
            guard shares.count > 1, length > 0 else { return }
            let before = forward ? min(position, shares.count - 2) : max(position - 1, 0)
            if forward {
                Self.shift(&shares, from: before + 1, to: before, points: points, length: length)
            } else {
                Self.shift(&shares, from: before, to: before + 1, points: points, length: length)
            }
        }
        switch arrangement {
        case .horizontal, .vertical:
            guard direction.isHorizontal == (arrangement == .horizontal) else { return }
            var shares = windows.map { weights[$0] ?? 1 }
            move(&shares, at: index, length: direction.isHorizontal ? area.width : area.height)
            for (window, share) in zip(windows, shares) { weights[window] = share }
        case .tiled:
            let grid = Self.grid(count: windows.count)
            let row = index / grid.columns
            if !direction.isHorizontal {
                var rows = currentRowWeights(grid)
                move(&rows, at: row, length: area.height)
                if grid.rows > 1 { rowWeights = rows }
                return
            }
            // the incomplete last row spreads evenly; full rows share the columns
            guard row < grid.rows - 1 || windows.count % grid.columns == 0 else { return }
            var columns = currentColumnWeights(grid)
            move(&columns, at: index % grid.columns, length: area.width)
            if grid.columns > 1 { columnWeights = columns }
        }
    }

    /// Move `points` of `length` from share `from` to share `to`, keeping
    /// each share above a tenth of the average.
    static func shift(_ shares: inout [Double], from: Int, to: Int, points: Double, length: Double) {
        let total = shares.reduce(0, +)
        let floor = total / Double(shares.count) * 0.1
        var change = points / length * total
        change = min(change, shares[from] - floor)
        change = max(change, -(shares[to] - floor))
        shares[to] += change
        shares[from] -= change
    }

    private func currentRowWeights(_ grid: (rows: Int, columns: Int)) -> [Double] {
        rowWeights.count == grid.rows ? rowWeights : Array(repeating: 1, count: grid.rows)
    }

    private func currentColumnWeights(_ grid: (rows: Int, columns: Int)) -> [Double] {
        columnWeights.count == grid.columns ? columnWeights : Array(repeating: 1, count: grid.columns)
    }

    // MARK: - Geometry

    /// tmux's layout_set_tiled: add a row, then a column, until every window has a cell.
    static func grid(count: Int) -> (rows: Int, columns: Int) {
        var rows = 1
        var columns = 1
        while rows * columns < count {
            rows += 1
            if rows * columns < count { columns += 1 }
        }
        return (rows, columns)
    }

    /// Raw tile boxes covering `area`. `minimums` (per window, gaps
    /// included) move the boundaries so every window gets at least its
    /// minimum while they fit.
    public func frames(in area: CGRect, minimums: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        guard !windows.isEmpty else { return [:] }
        var result: [WindowID: CGRect] = [:]
        switch arrangement {
        case .horizontal, .vertical:
            let vertical = arrangement == .vertical
            let shares = windows.map { weights[$0] ?? 1 }
            let needed = windows.map { id -> Double in vertical ? minimums[id]?.height ?? 0 : minimums[id]?.width ?? 0 }
            let lengths = Self.lengths(vertical ? area.height : area.width, shares: shares, minimums: needed)
            for (id, box) in zip(windows, Space.slices(area, lengths: lengths, vertical: vertical)) { result[id] = box }
        case .tiled:
            let grid = Self.grid(count: windows.count)
            let rows = rowsOfWindows(grid)
            let rowHeights = Self.lengths(area.height, shares: currentRowWeights(grid), minimums: rows.map { row in
                row.map { minimums[$0]?.height ?? 0 }.max() ?? 0
            })
            for (row, box) in zip(rows, Space.slices(area, lengths: rowHeights, vertical: true)) {
                let shares = row.count == grid.columns ? currentColumnWeights(grid) : Array(repeating: 1, count: row.count)
                let widths = Self.lengths(box.width, shares: shares, minimums: row.map { minimums[$0]?.width ?? 0 })
                for (id, cell) in zip(row, Space.slices(box, lengths: widths, vertical: false)) { result[id] = cell }
            }
        }
        return result
    }

    private func rowsOfWindows(_ grid: (rows: Int, columns: Int)) -> [[WindowID]] {
        stride(from: 0, to: windows.count, by: grid.columns).map { Array(windows[$0..<min($0 + grid.columns, windows.count)]) }
    }

    static func lengths(_ total: Double, shares: [Double], minimums: [Double]) -> [Double] {
        if let constrained = Space.distribute(total, weights: shares, minimums: minimums) { return constrained }
        let sum = shares.reduce(0, +)
        return shares.map { total * $0 / sum }
    }

    /// The smallest area every window fits in at its minimum.
    public func minimumSize(minimums: [WindowID: CGSize]) -> CGSize {
        let sizes = windows.map { minimums[$0] ?? .zero }
        switch arrangement {
        case .horizontal:
            return CGSize(width: sizes.reduce(0) { $0 + $1.width }, height: sizes.map(\.height).max() ?? 0)
        case .vertical:
            return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height })
        case .tiled:
            let rows = rowsOfWindows(Self.grid(count: windows.count))
            let width = rows.map { $0.reduce(0) { $0 + (minimums[$1]?.width ?? 0) } }.max() ?? 0
            let height = rows.reduce(0) { total, row in total + (row.map { minimums[$0]?.height ?? 0 }.max() ?? 0) }
            return CGSize(width: width, height: height)
        }
    }
}
