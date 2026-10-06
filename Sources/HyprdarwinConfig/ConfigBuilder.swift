import Foundation
import HyprdarwinCore

public struct ConfigMessage: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        /// The config was rejected; the previous one stays active.
        case error
        /// Applied, but something is probably wrong (unknown option, typo).
        case warning
        /// Applied; a Hyprland feature macOS cannot honour was ignored.
        case info
    }

    public var severity: Severity
    public var text: String

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }

    public var description: String { "\(severity.rawValue): \(text)" }
}

struct ConfigError: Error, CustomStringConvertible {
    var message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Accumulates what the config's hl.* calls declare into a `Config`.
struct ConfigBuilder {
    var config = Config()
    private(set) var messages: [ConfigMessage] = []
    private var seen: Set<String> = []

    mutating func note(_ severity: ConfigMessage.Severity, _ text: String) {
        guard seen.insert("\(severity.rawValue)|\(text)").inserted else { return }
        messages.append(ConfigMessage(severity, text))
    }

    // MARK: - hl.config

    /// Options that hold a table as their value instead of nesting further.
    static let tableValuedOptions: Set<String> = [
        "general.col.active_border", "general.col.inactive_border",
        "general.col.nogroup_border", "general.col.nogroup_border_active",
    ]

    /// Hyprland options in sections hyprdarwin partly supports that macOS cannot honour.
    static let ignoredOptions: [String: Set<String>] = [
        "general": [
            "no_border_on_floating", "gaps_workspaces", "float_gaps", "resize_on_border",
            "extend_border_grab_area", "hover_icon_on_border", "allow_tearing", "resize_corner",
            "locale", "modal_parent_blocking", "col.nogroup_border", "col.nogroup_border_active",
            "snap.enabled", "snap.window_gap", "snap.monitor_gap", "snap.border_overlap", "snap.respect_gaps",
        ],
        "dwindle": [
            "pseudotile", "smart_split", "smart_resizing", "permanent_direction_override",
            "special_scale_factor", "use_active_for_splits", "split_bias", "precise_mouse_move",
            "single_window_aspect_ratio", "single_window_aspect_ratio_tolerance",
        ],
        "master": [
            "allow_small_split", "special_scale_factor", "new_on_active", "inherit_fullscreen",
            "slave_count_for_center_master", "center_master_fallback", "smart_resizing",
            "drop_at_cursor", "always_keep_position",
        ],
        "input": [
            "kb_model", "kb_layout", "kb_variant", "kb_options", "kb_rules", "kb_file",
            "numlock_by_default", "resolve_binds_by_sym", "repeat_rate", "repeat_delay", "sensitivity",
            "accel_profile", "force_no_accel", "left_handed", "scroll_points", "scroll_method",
            "scroll_button", "scroll_button_lock", "scroll_factor", "natural_scroll",
            "follow_mouse_threshold", "focus_on_close", "mouse_refocus", "float_switch_override_focus",
            "special_fallthrough", "off_window_axis_events", "emulate_discrete_scroll",
        ],
    ]

    /// Sections whose sub-tables are all input-device settings (ignored).
    static let ignoredInputSubsections: Set<String> = ["touchpad", "touchdevice", "tablet", "virtualkeyboard"]

    /// Whole Hyprland sections macOS cannot honour.
    static let ignoredSections: Set<String> = [
        "decoration", "animations", "group", "xwayland", "render", "opengl", "ecosystem",
        "experimental", "debug", "gestures", "binds", "scrolling", "quirks", "plugin", "layerrule",
    ]

    mutating func applyOptions(_ table: LuaTable, location: String) throws {
        var entries: [(String, LuaValue)] = []
        Self.flatten(table, prefix: "", into: &entries)
        for (path, value) in entries {
            try applyOption(path, value, location: location)
        }
    }

    static func flatten(_ table: LuaTable, prefix: String, into entries: inout [(String, LuaValue)]) {
        for key in table.sortedKeys {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if case .table(let nested) = table[key], nested.array.isEmpty, !tableValuedOptions.contains(path) {
                flatten(nested, prefix: path, into: &entries)
            } else {
                entries.append((path, table[key]))
            }
        }
    }

    private mutating func applyOption(_ path: String, _ value: LuaValue, location: String) throws {
        func bad(_ expected: String) -> ConfigError {
            ConfigError("\(location) \(path): expected \(expected), got \(value.typeName) \(Self.render(value))")
        }
        switch path {
        case "general.layout":
            guard let text = value.text else { throw bad(Self.layoutNames) }
            if let kind = LayoutKind(rawValue: text) {
                config.layout = kind
            } else if ["scrolling", "monocle"].contains(text) {
                note(.warning, "\(location) general.layout: the \(text) layout is not supported yet; keeping \(config.layout.rawValue)")
            } else {
                throw bad(Self.layoutNames)
            }
        case "general.gaps_in", "general.gaps_out":
            guard let insets = Self.insets(value) else { throw bad("a number or a string like \"5 10 5 10\"") }
            if path == "general.gaps_in" { config.gapsIn = insets } else { config.gapsOut = insets }
        case "general.border_size":
            guard let size = value.int, size >= 0 else { throw bad("a whole number >= 0") }
            config.borderSize = size
        case "general.col.active_border", "general.col.inactive_border":
            guard let color = Self.borderColor(value) else {
                throw bad("a colour like \"rgba(33ccffee)\" or { colors = { ... }, angle = 45 }")
            }
            if path == "general.col.active_border" { config.activeBorder = color } else { config.inactiveBorder = color }
        case "dwindle.preserve_split":
            guard let flag = value.bool else { throw bad("a boolean") }
            config.layoutOptions.dwindle.preserveSplit = flag
        case "dwindle.force_split":
            guard let mode = value.int, (0...2).contains(mode) else { throw bad("0, 1 or 2") }
            config.layoutOptions.dwindle.forceSplit = mode
        case "dwindle.default_split_ratio":
            guard let ratio = value.double, (0.1...1.9).contains(ratio) else { throw bad("a number from 0.1 to 1.9") }
            config.layoutOptions.dwindle.defaultSplitRatio = ratio
        case "dwindle.split_width_multiplier":
            guard let factor = value.double, factor > 0 else { throw bad("a number > 0") }
            config.layoutOptions.dwindle.splitWidthMultiplier = factor
        case "master.mfact":
            guard let mfact = value.double, (0...1).contains(mfact) else { throw bad("a number from 0 to 1") }
            config.layoutOptions.master.mfact = min(max(mfact, MasterLayout.mfactRange.lowerBound), MasterLayout.mfactRange.upperBound)
        case "master.new_status":
            guard let text = value.text, let status = MasterNewStatus(rawValue: text) else {
                throw bad("\"master\", \"slave\" or \"inherit\"")
            }
            config.layoutOptions.master.newStatus = status
        case "master.new_on_top":
            guard let flag = value.bool else { throw bad("a boolean") }
            config.layoutOptions.master.newOnTop = flag
        case "master.orientation":
            guard let text = value.text else { throw bad("left, right, top or bottom") }
            if let orientation = MasterOrientation(rawValue: text) {
                config.layoutOptions.master.orientation = orientation
            } else if text == "center" {
                note(.warning, "\(location) master.orientation: center is not supported yet; using left")
                config.layoutOptions.master.orientation = .left
            } else {
                throw bad("left, right, top or bottom")
            }
        case "input.follow_mouse":
            guard let mode = value.int, (0...3).contains(mode) else { throw bad("0, 1, 2 or 3") }
            if mode >= 2 {
                note(.info, "\(location) input.follow_mouse = \(mode) behaves like 0 on macOS (focus changes on click)")
            }
            config.followMouse = mode == 1 ? 1 : 0
        case "cursor.no_warps":
            guard let flag = value.bool else { throw bad("a boolean") }
            config.noWarps = flag
        case "misc.disable_autoreload":
            guard let flag = value.bool else { throw bad("a boolean") }
            config.disableAutoreload = flag
        case "misc.focus_on_open":
            guard let flag = value.bool else { throw bad("a boolean") }
            config.focusOnOpen = flag
        default:
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            let section = parts[0]
            let rest = parts.count > 1 ? parts[1] : ""
            if Self.ignoredSections.contains(section) {
                note(.info, "\(section).* options are ignored on macOS")
            } else if section == "cursor" || section == "misc" {
                note(.info, "\(path) is ignored on macOS")
            } else if section == "input", let sub = rest.split(separator: ".").first, Self.ignoredInputSubsections.contains(String(sub)) {
                note(.info, "input.\(sub).* options are ignored on macOS")
            } else if let known = Self.ignoredOptions[section], known.contains(rest) {
                note(.info, "\(path) is ignored on macOS")
            } else {
                note(.warning, "\(location) unknown option \(path)")
            }
        }
    }

    static let layoutNames = LayoutKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")

    // MARK: - hd.config

    mutating func applyMacOptions(_ table: LuaTable, location: String) throws {
        for key in table.sortedKeys {
            let value = table[key]
            switch key {
            case "hypr_key":
                guard let text = value.text, let mode = HyprKeyMode(rawValue: text) else {
                    throw ConfigError("\(location) hd.config hypr_key: expected \"caps_lock\", \"f18\" or \"none\"")
                }
                config.hyprKey = mode
            case "border_radius":
                guard let radius = value.double, radius >= 0 else {
                    throw ConfigError("\(location) hd.config border_radius: expected a number >= 0")
                }
                config.borderRadius = radius
            case "unmanaged_apps":
                guard let list = value.tableValue, list.fields.isEmpty,
                      list.array.allSatisfy({ $0.text != nil }) else {
                    throw ConfigError("\(location) hd.config unmanaged_apps: expected a list of bundle ids, e.g. { \"com.mitchellh.ghostty\" }")
                }
                config.unmanagedApps = Set(list.array.compactMap(\.text))
            case "hide_corner":
                guard let text = value.text, let corner = HideCorner(rawValue: text) else {
                    throw ConfigError("\(location) hd.config hide_corner: expected \"bottom-right\" or \"bottom-left\"")
                }
                config.hideCorner = corner
            default:
                note(.warning, "\(location) unknown hd.config option \(key)")
            }
        }
    }

    // MARK: - hl.window_rule

    static let ignoredRuleEffects: [String: String] = [
        "opacity": "ignored on macOS", "no_blur": "ignored on macOS", "no_shadow": "ignored on macOS",
        "rounding": "ignored on macOS", "rounding_power": "ignored on macOS", "animation": "ignored on macOS",
        "no_anim": "ignored on macOS", "no_dim": "ignored on macOS", "dim_around": "ignored on macOS",
        "xray": "ignored on macOS", "decorate": "ignored on macOS", "idle_inhibit": "not supported yet",
        "suppress_event": "ignored on macOS", "keep_aspect_ratio": "ignored on macOS",
        "nearest_neighbor": "ignored on macOS", "no_screen_share": "ignored on macOS", "no_vrr": "ignored on macOS",
        "immediate": "ignored on macOS", "render_unfocused": "ignored on macOS", "allows_input": "ignored on macOS",
        "force_rgbx": "ignored on macOS", "sync_fullscreen": "ignored on macOS", "no_max_size": "ignored on macOS",
        "stay_focused": "not supported yet", "no_focus": "not supported yet", "focus_on_activate": "not supported yet",
        "scroll_mouse": "ignored on macOS", "scroll_touchpad": "ignored on macOS", "no_close_for": "not supported yet",
        "content": "ignored on macOS", "persistent_size": "not supported yet", "pseudo": "ignored on macOS",
        "group": "groups are not supported", "pin": "not supported yet", "fullscreen_state": "use fullscreen = true",
        "max_size": "not supported yet", "no_follow_mouse": "not supported yet",
    ]

    static let unsupportedMatchFields: Set<String> = [
        "pin", "focus", "group", "modal", "fullscreen_state_client", "fullscreen_state_internal",
        "content", "xdg_tag", "monitor", "x11", "on_workspace",
    ]

    /// Returns the rule's index in `config.windowRules`, or nil when the rule
    /// can never match on macOS and was dropped.
    mutating func addWindowRule(_ table: LuaTable, location: String) throws -> Int? {
        func fail(_ message: String) -> ConfigError { ConfigError("\(location) hl.window_rule: \(message)") }
        guard let matchTable = table["match"].tableValue else { throw fail("match = { ... } is required") }
        var match = WindowRuleMatch()
        var neverMatches = false
        for key in matchTable.sortedKeys {
            let value = matchTable[key]
            func pattern() throws -> RulePattern {
                guard let text = value.text else { throw fail("match.\(key) must be a string") }
                do {
                    return try RulePattern(text)
                } catch {
                    throw fail("match.\(key): invalid regular expression \"\(text)\"")
                }
            }
            func flag() throws -> Bool {
                guard let bool = value.bool else { throw fail("match.\(key) must be a boolean") }
                return bool
            }
            switch key {
            case "class": match.class = try pattern()
            case "title": match.title = try pattern()
            case "initial_class": match.initialClass = try pattern()
            case "initial_title": match.initialTitle = try pattern()
            case "app_name": match.appName = try pattern()
            case "role": match.role = try pattern()
            case "subrole": match.subrole = try pattern()
            case "tag": match.tag = try pattern()
            case "float": match.float = try flag()
            case "fullscreen": match.fullscreen = try flag()
            case "workspace":
                guard let text = value.text else { throw fail("match.workspace must be a string or number") }
                if let id = WorkspaceID(parsing: text) {
                    match.workspace = id
                } else {
                    note(.info, "\(location) hl.window_rule: workspace selector \"\(text)\" is not supported yet; the rule is skipped")
                    neverMatches = true
                }
            case "xwayland":
                // macOS has no XWayland: xwayland = true never matches, false always does
                if try flag() { neverMatches = true }
            default:
                if Self.unsupportedMatchFields.contains(key) {
                    note(.info, "\(location) hl.window_rule: match.\(key) is not supported on macOS; the rule is skipped")
                } else {
                    note(.warning, "\(location) hl.window_rule: unknown match field \"\(key)\"; the rule is skipped")
                }
                neverMatches = true
            }
        }
        if match.isEmpty && !neverMatches { throw fail("match needs at least one field") }

        var effects = WindowRuleEffects()
        for key in table.sortedKeys where !["match", "name", "enabled", "dynamic"].contains(key) {
            let value = table[key]
            func flag() throws -> Bool {
                guard let bool = value.bool else { throw fail("\(key) must be a boolean") }
                return bool
            }
            func text() throws -> String {
                guard let text = value.text else { throw fail("\(key) must be a string") }
                return text
            }
            switch key {
            case "float": effects.float = try flag()
            case "tile": effects.float = !(try flag())
            case "workspace":
                let raw = try text()
                guard let target = WorkspaceTarget(parsing: raw) else {
                    throw fail("workspace \"\(raw)\" should look like \"3\", \"3 silent\" or \"special:name\"")
                }
                effects.workspace = target
            case "monitor":
                let raw = try text()
                guard let selector = MonitorSelector(parsing: raw) else { throw fail("invalid monitor \"\(raw)\"") }
                effects.monitor = selector
            case "size", "move", "min_size":
                let raw = try text()
                if let problem = RuleExpression.validatePair(raw) { throw fail("\(key): \(problem)") }
                switch key {
                case "size": effects.size = raw
                case "move": effects.move = raw
                default: effects.minSize = raw
                }
            case "center": effects.center = try flag()
            case "fullscreen": if try flag() { effects.fullscreen = .fullscreen }
            case "maximize": if try flag() { effects.fullscreen = .maximized }
            case "no_initial_focus": effects.noInitialFocus = try flag()
            case "border_color":
                guard let color = Self.borderColor(value) else { throw fail("border_color must be a colour like \"rgba(33ccffee)\"") }
                effects.borderColor = color
            case "border_size":
                guard let size = value.int, size >= 0 else { throw fail("border_size must be a whole number >= 0") }
                effects.borderSize = size
            case "no_border": if try flag() { effects.borderSize = 0 }
            case "tag":
                let raw = try text()
                effects.tags.append(raw.hasPrefix("+") || raw.hasPrefix("-") ? String(raw.dropFirst()) : raw)
            default:
                if let reason = Self.ignoredRuleEffects[key] {
                    note(.info, "\(location) hl.window_rule: \(key) is \(reason)")
                } else {
                    note(.warning, "\(location) hl.window_rule: unknown effect \"\(key)\"")
                }
            }
        }
        guard !neverMatches else { return nil }
        var rule = WindowRule(name: table["name"].text, match: match, effects: effects)
        rule.enabled = table["enabled"].bool ?? true
        rule.dynamic = table["dynamic"].bool ?? false
        config.windowRules.append(rule)
        return config.windowRules.count - 1
    }

    // MARK: - hl.workspace_rule

    static let ignoredWorkspaceRuleFields: Set<String> = [
        "on_created_empty", "rounding", "decorate", "shadow", "border", "border_size", "no_rounding",
        "no_border", "no_shadow", "gaps_workspaces", "default_name", "animation", "layoutopt",
    ]

    mutating func addWorkspaceRule(_ table: LuaTable, location: String) throws {
        func fail(_ message: String) -> ConfigError { ConfigError("\(location) hl.workspace_rule: \(message)") }
        guard let selector = table["workspace"].text else { throw fail("workspace = ... is required") }
        guard let id = WorkspaceID(parsing: selector) else {
            note(.info, "\(location) hl.workspace_rule: workspace selector \"\(selector)\" is not supported yet; the rule is skipped")
            return
        }
        var rule = WorkspaceRule(workspace: id)
        for key in table.sortedKeys where key != "workspace" {
            let value = table[key]
            switch key {
            case "monitor":
                guard let monitor = value.text else { throw fail("monitor must be a string") }
                rule.monitor = monitor
            case "default":
                guard let flag = value.bool else { throw fail("default must be a boolean") }
                rule.isDefault = flag
            case "persistent":
                guard let flag = value.bool else { throw fail("persistent must be a boolean") }
                rule.persistent = flag
            case "layout":
                guard let text = value.text, let kind = LayoutKind(rawValue: text) else {
                    throw fail("layout must be one of \(Self.layoutNames)")
                }
                rule.layout = kind
            case "gaps_in", "gaps_out":
                guard let insets = Self.insets(value) else { throw fail("\(key) must be a number or a string like \"5 10\"") }
                if key == "gaps_in" { rule.gapsIn = insets } else { rule.gapsOut = insets }
            default:
                if Self.ignoredWorkspaceRuleFields.contains(key) {
                    note(.info, "\(location) hl.workspace_rule: \(key) is not supported on macOS (ignored)")
                } else {
                    note(.warning, "\(location) hl.workspace_rule: unknown field \"\(key)\"")
                }
            }
        }
        config.workspaceRules.append(rule)
    }

    // MARK: - hl.bind

    static let ignoredBindFlags: Set<String> = [
        "locked", "non_consuming", "ignore_mods", "transparent", "long_press", "separate",
        "dont_inhibit", "click", "drag", "submap_universal",
    ]

    mutating func addBind(keys: String, action: BindAction, flags: LuaTable, location: String) throws -> Int? {
        let usesMouse = flags["mouse"].bool == true
            || keys.split(whereSeparator: { $0 == "+" || $0.isWhitespace }).contains { $0.lowercased().hasPrefix("mouse") }
        if usesMouse {
            note(.warning, "\(location) hl.bind \"\(keys)\": mouse binds are not supported yet; the bind is skipped")
            return nil
        }
        let combo: KeyCombo
        switch KeyCombo.parse(keys) {
        case .success(let parsed): combo = parsed
        case .failure(let error): throw ConfigError("\(location) hl.bind \"\(keys)\": \(error)")
        }
        var bind = Keybind(combo: combo, submap: nil, action: action)
        for key in flags.sortedKeys {
            let value = flags[key]
            switch key {
            case "repeating":
                guard let flag = value.bool else { throw ConfigError("\(location) hl.bind: repeating must be a boolean") }
                bind.repeating = flag
            case "release":
                guard let flag = value.bool else { throw ConfigError("\(location) hl.bind: release must be a boolean") }
                bind.release = flag
            case "description", "desc":
                bind.description = value.text
            case "mouse":
                break
            default:
                if Self.ignoredBindFlags.contains(key) {
                    note(.info, "\(location) hl.bind: the \(key) flag is not supported on macOS (ignored)")
                } else {
                    note(.warning, "\(location) hl.bind: unknown flag \"\(key)\"")
                }
            }
        }
        if combo.modifiers.contains(.hypr), config.hyprKey == .none {
            note(.info, "\(location) hl.bind \"\(keys)\": hd.config hypr_key is \"none\", so HYPR binds never fire")
        }
        config.binds.append(bind)
        return config.binds.count - 1
    }

    // MARK: - Value helpers

    static func insets(_ value: LuaValue) -> Insets? {
        switch value {
        case .integer, .number:
            guard let number = value.double, number >= 0 else { return nil }
            return Insets(all: number)
        case .string(let text):
            let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let numbers = tokens.compactMap { Double($0) }
            guard numbers.count == tokens.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
            return Insets(css: numbers)
        default:
            return nil
        }
    }

    static func borderColor(_ value: LuaValue) -> BorderColor? {
        switch value {
        case .integer(let raw):
            guard raw >= 0, raw <= 0xFFFF_FFFF else { return nil }
            return Color(parsing: String(format: "0x%08llx", raw)).map { BorderColor(colors: [$0]) }
        case .string(let text):
            // "rgba(..)" or the hyprlang gradient form "rgba(..) rgba(..) 45deg"
            var colors: [Color] = []
            var angle = 0.0
            for token in text.split(whereSeparator: \.isWhitespace) {
                if token.hasSuffix("deg"), let degrees = Double(token.dropLast(3)) {
                    angle = degrees
                } else if let color = Color(parsing: String(token)) {
                    colors.append(color)
                } else {
                    return nil
                }
            }
            return colors.isEmpty ? nil : BorderColor(colors: colors, angle: angle)
        case .table(let table):
            let list = table["colors"].tableValue?.array ?? table.array
            var colors: [Color] = []
            for item in list {
                guard let single = borderColor(item), single.colors.count == 1 else { return nil }
                colors.append(single.colors[0])
            }
            guard !colors.isEmpty else { return nil }
            return BorderColor(colors: colors, angle: table["angle"].double ?? 0)
        default:
            return nil
        }
    }

    static func render(_ value: LuaValue) -> String {
        switch value {
        case .none: return "nil"
        case .bool(let flag): return String(flag)
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .string(let text): return "\"\(text)\""
        case .table: return "{...}"
        case .function: return "function"
        case .dispatcher: return "dispatcher"
        case .other(let name): return name
        }
    }
}
