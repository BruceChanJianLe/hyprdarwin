import CoreGraphics
import Foundation

/// CGWindowID of a managed window.
public typealias WindowID = UInt32

/// CGDirectDisplayID of a monitor.
public typealias MonitorID = UInt32

/// A Hyprland-style workspace: numbered (created on demand, no upper bound)
/// or special (a scratchpad shown over a monitor's regular workspace).
public enum WorkspaceID: Hashable, Sendable, Comparable, CustomStringConvertible {
    case numbered(Int)
    case special(String)

    public static let defaultSpecialName = "special"

    /// "3" or "special" / "special:name". Returns nil for anything else.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.first?.isNumber == true, let number = Int(trimmed), number >= 1 {
            self = .numbered(number)
        } else if trimmed == "special" {
            self = .special(Self.defaultSpecialName)
        } else if trimmed.hasPrefix("special:") {
            let name = String(trimmed.dropFirst("special:".count))
            self = .special(name.isEmpty ? Self.defaultSpecialName : name)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .numbered(let number): return String(number)
        case .special(let name): return "special:\(name)"
        }
    }

    public var isSpecial: Bool {
        if case .special = self { return true }
        return false
    }

    public var number: Int? {
        if case .numbered(let number) = self { return number }
        return nil
    }

    public static func < (lhs: WorkspaceID, rhs: WorkspaceID) -> Bool {
        switch (lhs, rhs) {
        case let (.numbered(a), .numbered(b)): return a < b
        case (.numbered, .special): return true
        case (.special, .numbered): return false
        case let (.special(a), .special(b)): return a < b
        }
    }
}

/// Workspace selectors as accepted by Hyprland's dispatchers.
public enum WorkspaceSelector: Equatable, Sendable, CustomStringConvertible {
    case id(WorkspaceID)
    /// "+1" / "-1" / "r+1": numeric offset from the current workspace.
    case relative(Int)
    /// "e+1" / "e-1": the next/previous existing workspace (any monitor).
    case existing(Int)
    /// "m+1" / "m-1": the next/previous existing workspace on this monitor.
    case existingOnMonitor(Int)
    /// "previous": the workspace focused before the current one.
    case previous
    /// "empty": the lowest-numbered workspace with no windows.
    case empty

    public init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let id = WorkspaceID(parsing: value) {
            self = .id(id)
            return
        }
        switch value {
        case "previous": self = .previous; return
        case "empty": self = .empty; return
        default: break
        }
        func offset(_ body: Substring) -> Int? {
            guard let first = body.first, first == "+" || first == "-" else { return nil }
            return Int(body)
        }
        if let delta = offset(Substring(value)) {
            self = .relative(delta)
        } else if value.hasPrefix("r"), let delta = offset(value.dropFirst()) {
            self = .relative(delta)
        } else if value.hasPrefix("e"), let delta = offset(value.dropFirst()) {
            self = .existing(delta)
        } else if value.hasPrefix("m"), let delta = offset(value.dropFirst()) {
            self = .existingOnMonitor(delta)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .id(let id): return id.description
        case .relative(let delta): return delta >= 0 ? "r+\(delta)" : "r\(delta)"
        case .existing(let delta): return delta >= 0 ? "e+\(delta)" : "e\(delta)"
        case .existingOnMonitor(let delta): return delta >= 0 ? "m+\(delta)" : "m\(delta)"
        case .previous: return "previous"
        case .empty: return "empty"
        }
    }
}

/// Monitor selectors: a name, an index, a direction, an offset or "current".
public enum MonitorSelector: Equatable, Sendable, CustomStringConvertible {
    case name(String)
    case index(Int)
    case direction(Direction)
    case relative(Int)
    case current

    public init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value == "current" {
            self = .current
        } else if let direction = Direction(parsing: value) {
            self = .direction(direction)
        } else if (value.hasPrefix("+") || value.hasPrefix("-")), let delta = Int(value) {
            self = .relative(delta)
        } else if let index = Int(value), index >= 0 {
            self = .index(index)
        } else {
            self = .name(value)
        }
    }

    public var description: String {
        switch self {
        case .name(let name): return name
        case .index(let index): return String(index)
        case .direction(let direction): return direction.rawValue
        case .relative(let delta): return delta >= 0 ? "+\(delta)" : String(delta)
        case .current: return "current"
        }
    }
}
