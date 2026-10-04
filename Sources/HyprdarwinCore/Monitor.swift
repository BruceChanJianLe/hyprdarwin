import CoreGraphics
import Foundation

public struct Monitor: Equatable, Sendable {
    public var id: MonitorID
    public var name: String
    /// Whole display, global top-left coordinates.
    public var frame: CGRect
    /// Display minus the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(id: MonitorID, name: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

extension Array where Element == Monitor {
    /// Left-to-right, then top-to-bottom: the order used for indexes and "+1".
    public var spatiallySorted: [Monitor] {
        sorted { a, b in
            if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
            return a.frame.minY < b.frame.minY
        }
    }

    /// The monitor holding most of `rect`, else the one nearest its centre.
    public func best(for rect: CGRect) -> Monitor? {
        var best: (Monitor, Double)?
        for monitor in self {
            let overlap = monitor.frame.intersection(rect)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.1 ?? 0) { best = (monitor, area) }
        }
        if let best { return best.0 }
        let centre = rect.center
        return self.min { a, b in
            hypot(a.frame.midX - centre.x, a.frame.midY - centre.y)
                < hypot(b.frame.midX - centre.x, b.frame.midY - centre.y)
        }
    }

    public func containing(_ point: CGPoint) -> Monitor? {
        first { $0.frame.contains(point) }
    }
}
