import CoreGraphics
import Foundation

/// A layout a workspace can use: Hyprland's dwindle and master, plus tmux's
/// seven (the main-* ones are master with a fixed orientation).
public enum LayoutKind: String, Sendable, CaseIterable {
    case dwindle
    /// Master with `master.orientation`.
    case master
    case evenHorizontal = "even-horizontal"
    case evenVertical = "even-vertical"
    case mainHorizontal = "main-horizontal"
    case mainHorizontalMirrored = "main-horizontal-mirrored"
    case mainVertical = "main-vertical"
    case mainVerticalMirrored = "main-vertical-mirrored"
    case tiled

    /// hd.dsp.cycle_layout's default loop: dwindle, then tmux's next-layout order.
    public static let defaultCycle: [LayoutKind] = [
        .dwindle, .evenHorizontal, .evenVertical, .mainHorizontal, .mainHorizontalMirrored,
        .mainVertical, .mainVerticalMirrored, .tiled,
    ]

    /// The master orientation of a main-* layout.
    var masterOrientation: MasterOrientation? {
        switch self {
        case .mainHorizontal: return .top
        case .mainHorizontalMirrored: return .bottom
        case .mainVertical: return .left
        case .mainVerticalMirrored: return .right
        default: return nil
        }
    }

    static func main(_ orientation: MasterOrientation) -> LayoutKind {
        switch orientation {
        case .top: return .mainHorizontal
        case .bottom: return .mainHorizontalMirrored
        case .left: return .mainVertical
        case .right: return .mainVerticalMirrored
        }
    }
}

public struct LayoutOptions: Equatable, Sendable {
    public var dwindle = DwindleOptions()
    public var master = MasterOptions()

    public init() {}
}

public struct LayoutMessageResult: Equatable, Sendable {
    /// Window the message wants focused afterwards (focusmaster, cyclenext...).
    public var focus: WindowID?
    public var error: String?

    public init(focus: WindowID? = nil, error: String? = nil) {
        self.focus = focus
        self.error = error
    }
}

/// The tiled windows of one workspace, arranged by one of the layouts.
public enum WorkspaceLayout: Equatable, Sendable {
    case dwindle(DwindleLayout)
    case master(MasterLayout)
    case even(EvenLayout)

    public init(kind: LayoutKind, options: LayoutOptions) {
        switch kind {
        case .dwindle: self = .dwindle(DwindleLayout())
        case .evenHorizontal: self = .even(EvenLayout(arrangement: .horizontal))
        case .evenVertical: self = .even(EvenLayout(arrangement: .vertical))
        case .tiled: self = .even(EvenLayout(arrangement: .tiled))
        case .master, .mainHorizontal, .mainHorizontalMirrored, .mainVertical, .mainVerticalMirrored:
            var layout = MasterLayout(options: options.master)
            if let orientation = kind.masterOrientation { layout.orientation = orientation }
            self = .master(layout)
        }
    }

    /// What the workspace looks like: master reports its main-* name.
    public var kind: LayoutKind {
        switch self {
        case .dwindle: return .dwindle
        case .master(let layout): return .main(layout.orientation)
        case .even(let layout):
            switch layout.arrangement {
            case .horizontal: return .evenHorizontal
            case .vertical: return .evenVertical
            case .tiled: return .tiled
            }
        }
    }

    /// True when this layout is what `kind` asks for (`master` accepts any orientation).
    public func isKind(_ kind: LayoutKind) -> Bool {
        if kind == .master, case .master = self { return true }
        return self.kind == kind
    }

    public var windows: [WindowID] {
        switch self {
        case .dwindle(let layout): return layout.windows
        case .master(let layout): return layout.windows
        case .even(let layout): return layout.windows
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .dwindle(let layout): return layout.contains(id)
        case .master(let layout): return layout.contains(id)
        case .even(let layout): return layout.contains(id)
        }
    }

    /// The same windows, in the same order, under another layout.
    public func converted(to kind: LayoutKind, area: CGRect, options: LayoutOptions) -> WorkspaceLayout {
        guard !isKind(kind) else { return self }
        return Self.build(kind: kind, windows: windows, area: area, options: options)
    }

    /// A fresh layout of the same kind holding `windows` in that order, with
    /// default split ratios, weights and mfact (re-tile).
    public func rebuilt(_ windows: [WindowID], area: CGRect, options: LayoutOptions) -> WorkspaceLayout {
        Self.build(kind: kind, windows: windows, area: area, options: options)
    }

    /// `windows` laid out in order, as if each opened after the previous one
    /// (dwindle's spiral), whatever force_split or new_status say.
    static func build(kind: LayoutKind, windows: [WindowID], area: CGRect, options: LayoutOptions) -> WorkspaceLayout {
        var layout = WorkspaceLayout(kind: kind, options: options)
        var buildOptions = options
        buildOptions.dwindle.forceSplit = 2
        buildOptions.master.newStatus = .slave
        buildOptions.master.newOnTop = false
        var previous: WindowID?
        for id in windows {
            layout.insert(id, focused: previous, area: area, options: buildOptions, cursor: nil)
            previous = id
        }
        return layout
    }

    public mutating func insert(
        _ id: WindowID, focused: WindowID?, area: CGRect, options: LayoutOptions, cursor: CGPoint?
    ) {
        switch self {
        case .dwindle(var layout):
            layout.insert(id, nextTo: focused, area: area, options: options.dwindle, cursor: cursor)
            self = .dwindle(layout)
        case .master(var layout):
            layout.insert(id, focused: focused, options: options.master)
            self = .master(layout)
        case .even(var layout):
            layout.insert(id, after: focused)
            self = .even(layout)
        }
    }

    public mutating func remove(_ id: WindowID) {
        switch self {
        case .dwindle(var layout):
            layout.remove(id)
            self = .dwindle(layout)
        case .master(var layout):
            layout.remove(id)
            self = .master(layout)
        case .even(var layout):
            layout.remove(id)
            self = .even(layout)
        }
    }

    public mutating func swap(_ a: WindowID, _ b: WindowID) {
        switch self {
        case .dwindle(var layout):
            layout.swap(a, b)
            self = .dwindle(layout)
        case .master(var layout):
            layout.swap(a, b)
            self = .master(layout)
        case .even(var layout):
            layout.swap(a, b)
            self = .even(layout)
        }
    }

    public mutating func replace(_ old: WindowID, with new: WindowID) {
        switch self {
        case .dwindle(var layout):
            layout.replace(old, with: new)
            self = .dwindle(layout)
        case .master(var layout):
            layout.replace(old, with: new)
            self = .master(layout)
        case .even(var layout):
            layout.replace(old, with: new)
            self = .even(layout)
        }
    }

    public mutating func resize(_ id: WindowID, dx: Double, dy: Double, area: CGRect, options: LayoutOptions) {
        switch self {
        case .dwindle(var layout):
            layout.resize(id, dx: dx, dy: dy, area: area, options: options.dwindle)
            self = .dwindle(layout)
        case .master(var layout):
            layout.resize(id, dx: dx, dy: dy, area: area)
            self = .master(layout)
        case .even(var layout):
            layout.resize(id, dx: dx, dy: dy, area: area)
            self = .even(layout)
        }
    }

    /// Raw tile boxes covering `area`, before gaps_in. `minimums` are the
    /// windows' minimum sizes, gaps included.
    public func frames(in area: CGRect, options: LayoutOptions, minimums: [WindowID: CGSize] = [:]) -> [WindowID: CGRect] {
        switch self {
        case .dwindle(let layout): return layout.frames(in: area, options: options.dwindle, minimums: minimums)
        case .master(let layout): return layout.frames(in: area, minimums: minimums)
        case .even(let layout): return layout.frames(in: area, minimums: minimums)
        }
    }

    /// The smallest area all the windows fit in at their minimum sizes.
    public func minimumSize(in area: CGRect, options: LayoutOptions, minimums: [WindowID: CGSize]) -> CGSize {
        switch self {
        case .dwindle(let layout): return layout.minimumSize(in: area, options: options.dwindle, minimums: minimums)
        case .master(let layout): return layout.minimumSize(minimums: minimums)
        case .even(let layout): return layout.minimumSize(minimums: minimums)
        }
    }

    /// Hyprland's `layoutmsg`. Dwindle: togglesplit, swapsplit, splitratio.
    /// Master: swapwithmaster, focusmaster, addmaster, removemaster, mfact,
    /// orientation{left,right,top,bottom,next,prev}, cyclenext/prev,
    /// swapnext/prev, rollnext/prev.
    public mutating func message(
        _ text: String, focused: WindowID?, area: CGRect, options: LayoutOptions
    ) -> LayoutMessageResult {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let command = words.first?.lowercased() else {
            return LayoutMessageResult(error: "empty layout message")
        }
        let args = Array(words.dropFirst())
        switch self {
        case .dwindle(var layout):
            defer { self = .dwindle(layout) }
            guard let focused, layout.contains(focused) else { return LayoutMessageResult() }
            switch command {
            case "togglesplit":
                layout.toggleSplit(focused, area: area, options: options.dwindle)
            case "swapsplit":
                layout.swapSplit(focused)
            case "splitratio":
                guard let change = Self.parseAdjustment(args) else {
                    return LayoutMessageResult(error: "splitratio expects a number or \"exact <number>\"")
                }
                layout.adjustRatio(focused, delta: change.delta, exact: change.exact)
            default:
                return LayoutMessageResult(error: "unknown dwindle layout message \"\(command)\"")
            }
            return LayoutMessageResult()
        case .master(var layout):
            defer { self = .master(layout) }
            switch command {
            case "swapwithmaster":
                guard let focused else { return LayoutMessageResult() }
                return LayoutMessageResult(focus: layout.swapWithMaster(focused))
            case "focusmaster":
                return LayoutMessageResult(focus: layout.windows.first)
            case "addmaster":
                layout.addMaster(focused)
            case "removemaster":
                layout.removeMaster(focused)
            case "mfact":
                guard let change = Self.parseAdjustment(args) else {
                    return LayoutMessageResult(error: "mfact expects a number or \"exact <number>\"")
                }
                layout.adjustMfact(delta: change.delta, exact: change.exact)
            case "orientationleft": layout.orientation = .left
            case "orientationright": layout.orientation = .right
            case "orientationtop": layout.orientation = .top
            case "orientationbottom": layout.orientation = .bottom
            case "orientationnext": layout.orientation = layout.orientation.next(1)
            case "orientationprev": layout.orientation = layout.orientation.next(-1)
            case "cyclenext":
                return LayoutMessageResult(focus: layout.cycle(from: focused, step: 1))
            case "cycleprev":
                return LayoutMessageResult(focus: layout.cycle(from: focused, step: -1))
            case "swapnext":
                guard let focused else { return LayoutMessageResult() }
                return LayoutMessageResult(focus: layout.swapInStack(focused, step: 1))
            case "swapprev":
                guard let focused else { return LayoutMessageResult() }
                return LayoutMessageResult(focus: layout.swapInStack(focused, step: -1))
            case "rollnext":
                layout.roll(step: 1)
                return LayoutMessageResult(focus: layout.windows.first)
            case "rollprev":
                layout.roll(step: -1)
                return LayoutMessageResult(focus: layout.windows.first)
            default:
                return LayoutMessageResult(error: "unknown master layout message \"\(command)\"")
            }
            return LayoutMessageResult()
        case .even:
            return LayoutMessageResult(error: "the \(kind.rawValue) layout takes no layout messages")
        }
    }

    static func parseAdjustment(_ args: [String]) -> (delta: Double?, exact: Double?)? {
        if args.count == 2, args[0].lowercased() == "exact", let value = Double(args[1]) {
            return (nil, value)
        }
        if args.count == 1, let value = Double(args[0]) {
            return (value, nil)
        }
        return nil
    }
}

public enum Gaps {
    /// Inset each tile by gaps_in on every side that touches another tile
    /// rather than the edge of `area` (so neighbours end up 2 * gaps_in apart,
    /// as in Hyprland).
    public static func apply(_ raw: [WindowID: CGRect], area: CGRect, gapsIn: Insets) -> [WindowID: CGRect] {
        raw.mapValues { frame in
            var insets = Insets.zero
            if frame.minX - area.minX > 0.5 { insets.left = gapsIn.left }
            if area.maxX - frame.maxX > 0.5 { insets.right = gapsIn.right }
            if frame.minY - area.minY > 0.5 { insets.top = gapsIn.top }
            if area.maxY - frame.maxY > 0.5 { insets.bottom = gapsIn.bottom }
            return frame.inset(by: insets).integral
        }
    }
}
