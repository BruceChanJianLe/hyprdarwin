import CoreGraphics
import Foundation

/// Sharing a length between tiles that each need a minimum (apps such as
/// browsers refuse to shrink below a size).
public enum Space {
    /// The first part's length when `total` is split in two, `desired` being
    /// what the layout wants for it. Each part gets at least its minimum while
    /// both fit; when they cannot, the parts share `total` in proportion to
    /// their minimums.
    public static func split(_ total: Double, desired: Double, minimums: (Double, Double)) -> Double {
        let (first, second) = minimums
        if first + second > total {
            return first + second > 0 ? total * first / (first + second) : desired
        }
        return min(max(desired, first), total - second)
    }

    /// `total` split into parts proportional to `weights`, except that every
    /// part gets at least its minimum: the difference comes out of the parts
    /// that have room, in proportion to their weights. When the minimums alone
    /// exceed `total`, the parts share it in proportion to their minimums.
    /// Returns nil when no minimum binds (callers keep their exact geometry).
    public static func distribute(_ total: Double, weights: [Double], minimums: [Double]) -> [Double]? {
        precondition(weights.count == minimums.count)
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else { return nil }
        let desired = weights.map { total * $0 / weightSum }
        guard zip(desired, minimums).contains(where: { $0 < $1 - 0.5 }) else { return nil }
        let minimumSum = minimums.reduce(0, +)
        if minimumSum >= total {
            return minimums.map { minimumSum > 0 ? total * $0 / minimumSum : total / Double(minimums.count) }
        }
        var fixed = Set<Int>()
        var sizes = desired
        while true {
            let free = weights.indices.filter { !fixed.contains($0) }
            let remaining = total - fixed.reduce(0) { $0 + minimums[$1] }
            let freeWeight = free.reduce(0) { $0 + weights[$1] }
            for index in free { sizes[index] = freeWeight > 0 ? remaining * weights[index] / freeWeight : remaining / Double(free.count) }
            for index in fixed { sizes[index] = minimums[index] }
            let short = free.filter { sizes[$0] < minimums[$0] }
            if short.isEmpty { return sizes }
            fixed.formUnion(short)
        }
    }

    /// `area` cut into consecutive slices of `lengths` along one axis.
    static func slices(_ area: CGRect, lengths: [Double], vertical: Bool) -> [CGRect] {
        var offset = vertical ? area.minY : area.minX
        return lengths.map { length in
            defer { offset += length }
            return vertical
                ? CGRect(x: area.minX, y: offset, width: area.width, height: length)
                : CGRect(x: offset, y: area.minY, width: length, height: area.height)
        }
    }
}
