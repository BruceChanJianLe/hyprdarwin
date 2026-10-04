import CoreGraphics
import Foundation

/// What a bind runs: a dispatcher, or a Lua function held by the config
/// runtime (the number is the runtime's reference for it).
public enum BindAction: Equatable, Sendable {
    case dispatcher(Dispatcher)
    case luaFunction(Int)
}

public struct Keybind: Sendable, Equatable {
    public var combo: KeyCombo
    /// nil for the global map, else the submap that owns the bind.
    public var submap: String?
    public var action: BindAction
    /// Fire again on key autorepeat while held.
    public var repeating = false
    /// Fire on key release instead of press.
    public var release = false
    public var description: String?
    public var enabled = true

    public init(combo: KeyCombo, submap: String?, action: BindAction) {
        self.combo = combo
        self.submap = submap
        self.action = action
    }
}

public struct WorkspaceRule: Sendable, Equatable {
    public var workspace: WorkspaceID
    public var monitor: String?
    /// Show this workspace on its monitor at startup.
    public var isDefault = false
    /// Keep the workspace alive when it is empty.
    public var persistent = false
    public var layout: LayoutKind?
    public var gapsIn: Insets?
    public var gapsOut: Insets?

    public init(workspace: WorkspaceID) {
        self.workspace = workspace
    }
}

/// How the Hypr modifier reaches the event tap.
public enum HyprKeyMode: String, Sendable {
    /// hyprdarwin maps Caps Lock to F18 with hidutil (and restores it on quit).
    case capsLock = "caps_lock"
    /// Something else already sends F18 (Karabiner, a keyboard's firmware).
    case f18
    /// No Hypr key; HYPR binds never fire.
    case none
}

public enum HideCorner: String, Sendable {
    case bottomRight = "bottom-right"
    case bottomLeft = "bottom-left"
}

public struct Color: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "rgba(33ccffee)", "rgb(33ccff)", "0xee33ccff" (Hyprland's AARRGGBB).
    public init?(parsing text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        func hexBytes(_ hex: Substring) -> [Double]? {
            guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
            var bytes: [Double] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(Double(UInt8(hex[index..<next], radix: 16)!) / 255)
                index = next
            }
            return bytes
        }
        if value.hasPrefix("rgba("), value.hasSuffix(")"),
           let b = hexBytes(value.dropFirst(5).dropLast()), b.count == 4 {
            self.init(red: b[0], green: b[1], blue: b[2], alpha: b[3])
        } else if value.hasPrefix("rgb("), value.hasSuffix(")"),
                  let b = hexBytes(value.dropFirst(4).dropLast()), b.count == 3 {
            self.init(red: b[0], green: b[1], blue: b[2], alpha: 1)
        } else if value.hasPrefix("0x"), let b = hexBytes(value.dropFirst(2)), b.count == 4 {
            self.init(red: b[1], green: b[2], blue: b[3], alpha: b[0])
        } else {
            return nil
        }
    }
}

/// Border colour: one colour or a gradient (drawn by the border overlay).
public struct BorderColor: Equatable, Sendable {
    public var colors: [Color]
    public var angle: Double

    public init(colors: [Color], angle: Double = 0) {
        self.colors = colors
        self.angle = angle
    }
}

/// An immutable snapshot of everything the config file declared.
public struct Config: Sendable {
    public var layout = LayoutKind.dwindle
    public var gapsIn = Insets(all: 5)
    public var gapsOut = Insets(all: 20)
    public var borderSize = 2
    public var activeBorder = BorderColor(colors: [Color(red: 0.2, green: 0.8, blue: 1, alpha: 0.93)])
    public var inactiveBorder = BorderColor(colors: [Color(red: 0.35, green: 0.35, blue: 0.35, alpha: 0.67)])
    public var layoutOptions = LayoutOptions()
    /// 0: focus only changes on click or keyboard; 1: focus follows the cursor.
    public var followMouse = 1
    /// Don't move the cursor to windows focused from the keyboard.
    public var noWarps = false
    public var disableAutoreload = false
    /// misc.focus_on_open: focus newly opened windows, switching to their
    /// workspace if needed. Off by default: new windows open silently.
    public var focusOnOpen = false
    /// hd.config unmanaged_apps: bundle ids hyprdarwin never touches.
    public var unmanagedApps: Set<String> = []
    public var hyprKey = HyprKeyMode.capsLock
    public var hideCorner = HideCorner.bottomRight

    public var binds: [Keybind] = []
    public var submaps: Set<String> = []
    public var windowRules: [WindowRule] = []
    public var workspaceRules: [WorkspaceRule] = []
    /// hl.env: exported to every process hyprdarwin launches.
    public var environment: [String: String] = [:]

    public init() {}

    /// All rules for `id` merged in order (later fields win), or nil.
    public func workspaceRule(for id: WorkspaceID) -> WorkspaceRule? {
        var merged: WorkspaceRule?
        for rule in workspaceRules where rule.workspace == id {
            var result = merged ?? WorkspaceRule(workspace: id)
            if let monitor = rule.monitor { result.monitor = monitor }
            if rule.isDefault { result.isDefault = true }
            if rule.persistent { result.persistent = true }
            if let layout = rule.layout { result.layout = layout }
            if let gapsIn = rule.gapsIn { result.gapsIn = gapsIn }
            if let gapsOut = rule.gapsOut { result.gapsOut = gapsOut }
            merged = result
        }
        return merged
    }
}
