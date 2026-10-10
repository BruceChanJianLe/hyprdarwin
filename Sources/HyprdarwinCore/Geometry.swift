import CoreGraphics
import Foundation

/// All rectangles in hyprdarwin use the global CoreGraphics / Accessibility
/// space: origin at the top-left of the primary display, y grows downward.

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down

    /// Accepts Hyprland's spellings: "l", "left", "r", "right", "u", "up", "t",
    /// "top", "d", "down", "b", "bottom".
    public init?(parsing text: String) {
        switch text.lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "up", "t", "top": self = .up
        case "d", "down", "b", "bottom": self = .down
        default: return nil
        }
    }

    public var isHorizontal: Bool { self == .left || self == .right }
    /// Right or down: towards larger coordinates.
    public var isIncreasing: Bool { self == .right || self == .down }
}

/// Per-side spacing, CSS order like Hyprland's gaps ("top right bottom left").
public struct Insets: Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(all value: Double) {
        self.init(top: value, right: value, bottom: value, left: value)
    }

    public static let zero = Insets(all: 0)

    /// One to four numbers, CSS shorthand: "5", "5 10", "5 10 15", "5 10 15 20".
    public init?(css values: [Double]) {
        switch values.count {
        case 1: self.init(all: values[0])
        case 2: self.init(top: values[0], right: values[1], bottom: values[0], left: values[1])
        case 3: self.init(top: values[0], right: values[1], bottom: values[2], left: values[1])
        case 4: self.init(top: values[0], right: values[1], bottom: values[2], left: values[3])
        default: return nil
        }
    }
}

extension CGRect {
    public func inset(by insets: Insets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: Swift.max(1, width - insets.left - insets.right),
            height: Swift.max(1, height - insets.top - insets.bottom)
        )
    }

    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rounded to whole points, which is what AX stores anyway.
    public var integral: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }

    public func isClose(to other: CGRect, tolerance: Double = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

/// Geometric neighbour search used by directional focus, swap and move.
public enum Neighbor {
    /// The candidate closest to `origin` in `direction`. A candidate qualifies
    /// when it lies past the origin's edge in that direction; candidates that
    /// overlap the origin on the perpendicular axis win over ones that do not,
    /// then the shortest edge distance, then the closest centres.
    public static func find<ID>(
        from origin: CGRect,
        direction: Direction,
        among candidates: [(id: ID, frame: CGRect)]
    ) -> ID? {
        var best: (id: ID, overlaps: Bool, distance: Double, centre: Double)?
        for candidate in candidates {
            let frame = candidate.frame
            let distance: Double
            let overlap: Double
            switch direction {
            case .left:
                guard frame.midX < origin.midX, frame.maxX <= origin.minX + 1 || frame.midX < origin.minX else { continue }
                distance = Swift.max(0, origin.minX - frame.maxX)
                overlap = Swift.min(frame.maxY, origin.maxY) - Swift.max(frame.minY, origin.minY)
            case .right:
                guard frame.midX > origin.midX, frame.minX >= origin.maxX - 1 || frame.midX > origin.maxX else { continue }
                distance = Swift.max(0, frame.minX - origin.maxX)
                overlap = Swift.min(frame.maxY, origin.maxY) - Swift.max(frame.minY, origin.minY)
            case .up:
                guard frame.midY < origin.midY, frame.maxY <= origin.minY + 1 || frame.midY < origin.minY else { continue }
                distance = Swift.max(0, origin.minY - frame.maxY)
                overlap = Swift.min(frame.maxX, origin.maxX) - Swift.max(frame.minX, origin.minX)
            case .down:
                guard frame.midY > origin.midY, frame.minY >= origin.maxY - 1 || frame.midY > origin.maxY else { continue }
                distance = Swift.max(0, frame.minY - origin.maxY)
                overlap = Swift.min(frame.maxX, origin.maxX) - Swift.max(frame.minX, origin.minX)
            }
            let overlaps = overlap > 0
            let centre = Double(hypot(frame.midX - origin.midX, frame.midY - origin.midY))
            if let current = best {
                if current.overlaps != overlaps {
                    if overlaps { best = (candidate.id, overlaps, distance, centre) }
                    continue
                }
                if distance < current.distance - 0.5
                    || (abs(distance - current.distance) <= 0.5 && centre < current.centre) {
                    best = (candidate.id, overlaps, distance, centre)
                }
            } else {
                best = (candidate.id, overlaps, distance, centre)
            }
        }
        return best?.id
    }
}
