import Foundation
import HyprdarwinCore

/// Turns an hl.dsp.* call (name plus Lua arguments) into a `Dispatcher`,
/// following the argument shapes of Hyprland 0.56's Lua bindings.
enum DispatcherParser {
    struct Outcome {
        var dispatcher: Dispatcher
        /// Non-fatal notes, e.g. "hl.dsp.window.pin is not supported".
        var notes: [String] = []
        /// The name is not a Hyprland dispatcher at all (likely a typo).
        var isUnknown = false
    }

    /// Dispatchers hyprdarwin accepts but cannot honour on macOS; they become no-ops.
    static let unsupported: [String: String] = [
        "window.pseudo": "pseudotiling is not supported",
        "window.pin": "pinning is not supported yet",
        "window.signal": "signals are not supported",
        "window.tag": "window.tag is not supported yet",
        "window.clear_tags": "window.clear_tags is not supported yet",
        "window.toggle_swallow": "swallowing is not supported",
        "window.bring_to_top": "z-order control is not supported",
        "window.alter_zorder": "z-order control is not supported",
        "window.set_prop": "window.set_prop is not supported",
        "window.deny_from_group": "groups are not supported",
        "window.drag": "mouse binds are not supported yet",
        "window.fullscreen_state": "use hl.dsp.window.fullscreen",
        "workspace.rename": "named workspaces are not supported",
        "workspace.change_id": "workspace.change_id is not supported",
        "workspace.swap_monitors": "workspace.swap_monitors is not supported yet",
        "pass": "hl.dsp.pass is not supported",
        "send_shortcut": "hl.dsp.send_shortcut is not supported",
        "send_key_state": "hl.dsp.send_key_state is not supported",
        "dpms": "dpms is not supported on macOS",
        "event": "custom events are not supported yet",
        "global": "global shortcuts are not supported",
        "force_renderer_reload": "there is no renderer to reload on macOS",
        "force_idle": "idle control is not supported",
        "release_input_capture": "input capture is not supported",
    ]

    static func parse(_ name: String, _ args: [LuaValue]) -> Result<Outcome, ConfigError> {
        let display = name.hasPrefix("hd.") ? "hd.dsp.\(name.dropFirst(3))" : "hl.dsp.\(name)"
        let first = args.first ?? .none
        let table = first.tableValue ?? LuaTable()
        func fail(_ message: String) -> Result<Outcome, ConfigError> {
            .failure(ConfigError("\(display): \(message)"))
        }
        func ok(_ dispatcher: Dispatcher, _ notes: [String] = []) -> Result<Outcome, ConfigError> {
            .success(Outcome(dispatcher: dispatcher, notes: notes))
        }
        func notes(ignoring keys: Set<String>) -> [String] {
            var result: [String] = []
            if table["window"] != .none && !keys.contains("window") {
                result.append("\(display): the window argument is not supported yet; the focused window is used")
            }
            return result
        }
        func toggle(_ key: String = "action") -> ToggleAction? {
            guard let text = table[key].text else { return table[key] == .none ? .toggle : nil }
            return ToggleAction(rawValue: text)
        }

        if let reason = unsupported[name] {
            return ok(.noOp, ["\(display): \(reason) (ignored on hyprdarwin)"])
        }

        switch name {
        case "exec_cmd", "exec_raw":
            guard let command = first.text, !command.isEmpty else { return fail("expected a command string") }
            var extra: [String] = []
            if args.count > 1, args[1] != .none {
                extra.append("hl.dsp.exec_cmd: exec rules are not supported yet; the command still runs")
            }
            return ok(.exec(command), extra)
        case "exit":
            return ok(.exit)
        case "reload_config":
            return ok(.reload)
        case "no_op":
            return ok(.noOp)
        case "submap":
            guard let submap = first.text else { return fail("expected a submap name") }
            return ok(.submap(submap))
        case "layout":
            guard let message = first.text, !message.isEmpty else { return fail("expected a layout message such as \"togglesplit\"") }
            return ok(.layoutMessage(message))

        case "focus":
            guard first.tableValue != nil else { return fail("expected a table, e.g. { direction = \"left\" }") }
            if let text = table["direction"].text {
                guard let direction = Direction(parsing: text) else { return fail("invalid direction \"\(text)\"") }
                return ok(.focusDirection(direction))
            }
            if let text = table["monitor"].text {
                guard let selector = MonitorSelector(parsing: text) else { return fail("invalid monitor \"\(text)\"") }
                return ok(.focusMonitor(selector))
            }
            if let text = table["workspace"].text {
                guard let selector = WorkspaceSelector(parsing: text) else { return fail("invalid workspace \"\(text)\"") }
                return ok(.focusWorkspace(selector, onCurrentMonitor: table["on_current_monitor"].bool ?? false))
            }
            if table["window"] != .none {
                return ok(.noOp, ["hl.dsp.focus: window selectors are not supported yet (ignored)"])
            }
            if table["last"].bool == true || table["urgent_or_last"].bool == true {
                return ok(.focusLast)
            }
            return fail("expected one of direction, monitor, workspace, last")

        case "window.close":
            return ok(.closeWindow, notes(ignoring: []))
        case "window.kill":
            return ok(.killWindow, notes(ignoring: []))
        case "window.float":
            guard let action = toggle() else { return fail("action must be toggle, set or unset") }
            return ok(.float(action), notes(ignoring: []))
        case "window.fullscreen":
            guard let action = toggle() else { return fail("action must be toggle, set or unset") }
            var mode = FullscreenMode.fullscreen
            if let text = table["mode"].text {
                switch text {
                case "fullscreen", "0": mode = .fullscreen
                case "maximized", "1": mode = .maximized
                default: return fail("invalid mode \"\(text)\" (expected fullscreen or maximized)")
                }
            }
            return ok(.fullscreen(mode, action), notes(ignoring: []))
        case "window.move":
            guard first.tableValue != nil else { return fail("expected a table, e.g. { direction = \"left\" }") }
            if let text = table["direction"].text {
                guard let direction = Direction(parsing: text) else { return fail("invalid direction \"\(text)\"") }
                return ok(.moveDirection(direction), notes(ignoring: []))
            }
            if let x = table["x"].double, let y = table["y"].double {
                return ok(.moveBy(x: x, y: y, relative: table["relative"].bool ?? false), notes(ignoring: []))
            }
            let follow = table["follow"].bool ?? true
            if let text = table["workspace"].text {
                guard let selector = WorkspaceSelector(parsing: text) else { return fail("invalid workspace \"\(text)\"") }
                return ok(.moveToWorkspace(selector, follow: follow), notes(ignoring: []))
            }
            if let text = table["monitor"].text {
                guard let selector = MonitorSelector(parsing: text) else { return fail("invalid monitor \"\(text)\"") }
                return ok(.moveToMonitor(selector, follow: follow), notes(ignoring: []))
            }
            if table["into_group"] != .none || table["into_or_create_group"] != .none || table["out_of_group"] != .none {
                return ok(.noOp, ["hl.dsp.window.move: groups are not supported (ignored)"])
            }
            return fail("expected one of direction, x+y, workspace, monitor")
        case "window.swap":
            guard let text = table["direction"].text else {
                if table["target"] != .none || table["with"] != .none || table["other"] != .none {
                    return ok(.noOp, ["hl.dsp.window.swap: window selectors are not supported yet (ignored)"])
                }
                return fail("expected { direction = ... }")
            }
            guard let direction = Direction(parsing: text) else { return fail("invalid direction \"\(text)\"") }
            return ok(.swapDirection(direction), notes(ignoring: []))
        case "window.resize":
            if let x = table["x"].double, let y = table["y"].double {
                return ok(.resize(x: x, y: y, relative: table["relative"].bool ?? false), notes(ignoring: []))
            }
            if first == .none || table["keep_aspect_ratio"] != .none {
                return ok(.noOp, ["hl.dsp.window.resize: mouse resizing is not supported yet (ignored)"])
            }
            return fail("expected { x = ..., y = ..., relative = true|false }")
        case "window.center":
            return ok(.center, notes(ignoring: []))
        case "window.cycle_next":
            // Hyprland's cyclenext [prev] [tiled|floating]
            let reverse = table["prev"].bool == true || table["next"].bool == false
            var filter = CycleFilter.all
            if table["floating"].bool == true { filter = .floating }
            if table["tiled"].bool == true { filter = .tiled }
            var extra: [String] = []
            if table["visible"] != .none || table["hist"] != .none {
                extra.append("hl.dsp.window.cycle_next: visible and hist are not supported yet (ignored)")
            }
            return ok(.cycleWindows(filter, reverse: reverse), extra)

        case "hd.cycle_layout":
            let direction = first.text ?? table["direction"].text ?? "next"
            switch direction {
            case "next", "+1": return ok(.cycleLayout(reverse: false))
            case "prev", "previous", "-1": return ok(.cycleLayout(reverse: true))
            default: return fail("direction must be \"next\" or \"prev\"")
            }
        case "hd.retile":
            return ok(.retile)

        case "workspace.toggle_special":
            return ok(.toggleSpecial(first.text ?? ""))
        case "workspace.move":
            guard let monitorText = table["monitor"].text, let monitor = MonitorSelector(parsing: monitorText) else {
                return fail("expected { monitor = ..., workspace = ... }")
            }
            var workspace: WorkspaceSelector?
            if let text = table["workspace"].text {
                guard let selector = WorkspaceSelector(parsing: text) else { return fail("invalid workspace \"\(text)\"") }
                workspace = selector
            }
            return ok(.moveWorkspaceToMonitor(workspace, monitor))

        default:
            if name.hasPrefix("group.") || name.hasPrefix("cursor.") {
                return ok(.noOp, ["\(display) is not supported on hyprdarwin (ignored)"])
            }
            var outcome = Outcome(dispatcher: .noOp, notes: ["\(display) is not a known dispatcher (ignored)"])
            outcome.isUnknown = true
            return .success(outcome)
        }
    }
}
