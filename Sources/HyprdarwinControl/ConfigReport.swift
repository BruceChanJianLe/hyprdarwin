import Foundation
import HyprdarwinConfig
import HyprdarwinCore

/// The effective config in readable rows, for the settings window and the
/// binds query: every option with its value (flagged when it differs from
/// the built-in default), the binds, and the window and workspace rules.
public struct ConfigReport: Equatable, Sendable {
    public struct Option: Equatable, Sendable, Identifiable {
        /// The hl.config path (`general.gaps_in`) or `hd.<name>` / `hl.env <NAME>`.
        public var name: String
        /// In Lua syntax, as it would be written in the config.
        public var value: String
        /// The built-in default, the same syntax.
        public var defaultValue: String
        /// Differs from the built-in default (changed by the config).
        public var isSet: Bool { value != defaultValue }
        public var id: String { name }
    }

    public struct Bind: Equatable, Sendable, Identifiable {
        public var id: Int
        public var keys: String
        /// "" for the global map.
        public var submap: String
        public var action: String
        public var description: String
        /// "repeating", "release".
        public var flags: [String]
        public var enabled: Bool
    }

    public struct WindowRule: Equatable, Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var match: [String]
        public var effects: [String]
        public var dynamic: Bool
        public var enabled: Bool
    }

    public struct WorkspaceRule: Equatable, Sendable, Identifiable {
        public var id: Int
        public var workspace: String
        public var settings: [String]
    }

    public var options: [Option]
    public var binds: [Bind]
    public var windowRules: [WindowRule]
    public var workspaceRules: [WorkspaceRule]
    public var submaps: [String]

    public init(config: Config) {
        options = Self.options(config)
        binds = config.binds.enumerated().map { index, bind in
            Bind(id: index, keys: bind.combo.description, submap: bind.submap ?? "", action: Self.action(bind.action),
                 description: bind.description ?? "",
                 flags: [bind.repeating ? "repeating" : nil, bind.release ? "release" : nil].compactMap { $0 },
                 enabled: bind.enabled)
        }
        windowRules = config.windowRules.enumerated().map { index, rule in
            WindowRule(id: index, name: rule.name ?? "", match: Self.match(rule.match), effects: Self.effects(rule.effects),
                       dynamic: rule.dynamic, enabled: rule.enabled)
        }
        workspaceRules = config.workspaceRules.enumerated().map { index, rule in
            WorkspaceRule(id: index, workspace: rule.workspace.description, settings: Self.settings(rule))
        }
        submaps = config.submaps.sorted()
    }

    // MARK: - Formatting

    public static func action(_ action: BindAction) -> String {
        switch action {
        case .dispatcher(let dispatcher): return dispatcher.description
        case .luaFunction: return "lua function"
        }
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    static func string(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func insets(_ insets: Insets) -> String {
        let sides = [insets.top, insets.right, insets.bottom, insets.left]
        if Set(sides).count == 1 { return number(insets.top) }
        return string(sides.map(number).joined(separator: " "))
    }

    /// Hyprland's colour syntax: "rgba(33ccffee) rgba(00ff99ee) 45deg".
    public static func color(_ border: BorderColor) -> String {
        func hex(_ component: Double) -> String {
            let byte = Int((min(max(component, 0), 1) * 255).rounded())
            return String(format: "%02x", byte)
        }
        var parts = border.colors.map { "rgba(\(hex($0.red))\(hex($0.green))\(hex($0.blue))\(hex($0.alpha)))" }
        if border.colors.count > 1 || border.angle != 0 { parts.append("\(number(border.angle))deg") }
        return parts.joined(separator: " ")
    }

    static func options(_ config: Config) -> [Option] {
        let defaults = Config()
        var rows: [Option] = []
        func add(_ name: String, _ value: String, _ defaultValue: String) {
            rows.append(Option(name: name, value: value, defaultValue: defaultValue))
        }
        func add<T>(_ name: String, _ path: KeyPath<Config, T>, _ format: (T) -> String) {
            add(name, format(config[keyPath: path]), format(defaults[keyPath: path]))
        }
        let bool: (Bool) -> String = { $0 ? "true" : "false" }
        add("general.layout", \.layout) { string($0.rawValue) }
        add("general.gaps_in", \.gapsIn, insets)
        add("general.gaps_out", \.gapsOut, insets)
        add("general.border_size", \.borderSize) { String($0) }
        add("general.col.active_border", \.activeBorder) { string(color($0)) }
        add("general.col.inactive_border", \.inactiveBorder) { $0.map { string(color($0)) } ?? "nil" }
        add("dwindle.preserve_split", \.layoutOptions.dwindle.preserveSplit, bool)
        add("dwindle.force_split", \.layoutOptions.dwindle.forceSplit) { String($0) }
        add("dwindle.default_split_ratio", \.layoutOptions.dwindle.defaultSplitRatio, number)
        add("dwindle.split_width_multiplier", \.layoutOptions.dwindle.splitWidthMultiplier, number)
        add("master.mfact", \.layoutOptions.master.mfact, number)
        add("master.new_status", \.layoutOptions.master.newStatus) { string($0.rawValue) }
        add("master.new_on_top", \.layoutOptions.master.newOnTop, bool)
        add("master.orientation", \.layoutOptions.master.orientation) { string($0.rawValue) }
        add("input.follow_mouse", \.followMouse) { String($0) }
        add("cursor.no_warps", \.noWarps, bool)
        add("misc.disable_autoreload", \.disableAutoreload, bool)
        add("misc.focus_on_open", \.focusOnOpen, bool)
        add("hd.hypr_key", \.hyprKey) { string($0.rawValue) }
        add("hd.hide_corner", \.hideCorner) { string($0.rawValue) }
        add("hd.border_radius", \.borderRadius, number)
        add("hd.unmanaged_apps", \.unmanagedApps) { "{ " + $0.sorted().map(string).joined(separator: ", ") + ($0.isEmpty ? "}" : " }") }
        for (name, value) in config.environment.sorted(by: { $0.key < $1.key }) {
            rows.append(Option(name: "hl.env \(name)", value: string(value), defaultValue: "nil"))
        }
        return rows
    }

    static func match(_ match: WindowRuleMatch) -> [String] {
        var parts: [String] = []
        func pattern(_ name: String, _ value: RulePattern?) {
            if let value { parts.append("\(name) = \(string(value.source))") }
        }
        pattern("class", match.class)
        pattern("title", match.title)
        pattern("initial_class", match.initialClass)
        pattern("initial_title", match.initialTitle)
        pattern("app_name", match.appName)
        pattern("role", match.role)
        pattern("subrole", match.subrole)
        pattern("tag", match.tag)
        if let float = match.float { parts.append("float = \(float)") }
        if let fullscreen = match.fullscreen { parts.append("fullscreen = \(fullscreen)") }
        if let workspace = match.workspace { parts.append("workspace = \(string(workspace.description))") }
        return parts
    }

    static func effects(_ effects: WindowRuleEffects) -> [String] {
        var parts: [String] = []
        if let float = effects.float { parts.append(float ? "float" : "tile") }
        if let target = effects.workspace { parts.append("workspace = \(string(target.workspace.description + (target.silent ? " silent" : "")))") }
        if let monitor = effects.monitor { parts.append("monitor = \(string(monitor.description))") }
        if let size = effects.size { parts.append("size = \(string(size))") }
        if let move = effects.move { parts.append("move = \(string(move))") }
        if let minSize = effects.minSize { parts.append("min_size = \(string(minSize))") }
        if effects.center == true { parts.append("center") }
        switch effects.fullscreen {
        case .fullscreen?: parts.append("fullscreen")
        case .maximized?: parts.append("maximize")
        case nil: break
        }
        if effects.noInitialFocus == true { parts.append("no_initial_focus") }
        for tag in effects.tags { parts.append("tag = \(string(tag))") }
        if let border = effects.borderColor { parts.append("border_color = \(string(color(border)))") }
        if let size = effects.borderSize { parts.append(size == 0 ? "no_border" : "border_size = \(size)") }
        return parts
    }

    static func settings(_ rule: HyprdarwinCore.WorkspaceRule) -> [String] {
        var parts: [String] = []
        if let monitor = rule.monitor { parts.append("monitor = \(string(monitor))") }
        if rule.isDefault { parts.append("default") }
        if rule.persistent { parts.append("persistent") }
        if let layout = rule.layout { parts.append("layout = \(string(layout.rawValue))") }
        if let gaps = rule.gapsIn { parts.append("gaps_in = \(insets(gaps))") }
        if let gaps = rule.gapsOut { parts.append("gaps_out = \(insets(gaps))") }
        return parts
    }
}
