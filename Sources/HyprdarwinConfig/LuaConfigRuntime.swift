import CLua
import Foundation
import HyprdarwinCore

/// What config code asked for while running outside the initial load
/// (or during it, for exec_cmd and called dispatchers).
public enum RuntimeAction: Equatable, Sendable {
    case dispatch(Dispatcher)
    case setWindowRuleEnabled(Int, Bool)
    case setBindEnabled(Int, Bool)
}

public struct CallOutcome: Equatable, Sendable {
    public var actions: [RuntimeAction] = []
    public var error: String?
    /// print() output and notes produced by the call.
    public var messages: [ConfigMessage] = []
}

public enum ConfigEvent: String, Sendable {
    case start
    case shutdown

    /// Names accepted by hl.on for each event.
    var names: [String] {
        switch self {
        case .start: return ["hyprland.start", "hyprdarwin.start"]
        case .shutdown: return ["hyprland.shutdown", "hyprdarwin.shutdown"]
        }
    }
}

/// One Lua state running one version of the config. A fresh runtime is made
/// for every load; the active one stays alive so Lua-function binds, rule
/// handles and hl.on callbacks keep working until the next good load.
///
/// Main-thread only.
public final class LuaConfigRuntime {
    static let dispatcherKey = "__hd_dispatcher"
    static let handleKey = "__hd_handle"
    static let handleKindKey = "__hd_kind"
    static let dispatcherMeta = "hd.dispatcher"
    static let handleMeta = "hd.handle"
    static let loadedKey = "hd.loaded"

    /// Instruction budgets: the whole load, and each later callback.
    static let loadBudget: Int64 = 50_000_000
    static let callbackBudget: Int64 = 10_000_000

    enum Builtin: Int32 {
        case config = 1
        case bind
        case windowRule
        case workspaceRule
        case defineSubmap
        case on
        case execCmd
        case env
        case ignored
        case unknownFunction
        case print
        case require
        case dispatcher
        case callDispatcher
        case setEnabled
        case isEnabled
        case macConfig
        case dispatcherNamespaceIndex
        case hlIndex
    }

    private(set) var L: OpaquePointer!
    let directory: String
    var builder = ConfigBuilder()
    var dispatchers: [Dispatcher] = []
    var isLoading = true
    var currentSubmap: String?
    var callbacks: [String: [Int32]] = [:]
    var pendingActions: [RuntimeAction] = []
    var callMessages: [ConfigMessage] = []
    /// Files the config read (main file first).
    var files: [String] = []
    /// Lua handle number -> rule index (nil when the rule was dropped).
    var ruleHandles: [Int?] = []
    var bindHandles: [Int?] = []

    private static let installHandler: Void = {
        hd_set_handler { state, id in
            guard let state, let owner = hd_owner(state) else { return 0 }
            let runtime = Unmanaged<LuaConfigRuntime>.fromOpaque(owner).takeUnretainedValue()
            return runtime.handle(state, id)
        }
    }()

    init(directory: String) {
        self.directory = directory
        _ = Self.installHandler
        L = hd_newstate(Unmanaged.passUnretained(self).toOpaque())
        installAPI()
    }

    deinit {
        if let L { hd_close(L) }
    }

    public var config: Config { builder.config }

    // MARK: - API tables

    private func pushBuiltin(_ builtin: Builtin, _ name: String? = nil) {
        hd_push_builtin(L, builtin.rawValue, name)
    }

    private func setBuiltin(_ field: String, _ builtin: Builtin, _ name: String? = nil) {
        pushBuiltin(builtin, name)
        lua_setfield(L, -2, field)
    }

    private func installAPI() {
        // dispatcher objects are callable: calling one runs it
        _ = luaL_newmetatable(L, Self.dispatcherMeta)
        setBuiltin("__call", .callDispatcher)
        lua_pushstring(L, "hl.dispatcher")
        lua_setfield(L, -2, "__name")
        hd_pop(L, 1)

        // rule and bind handles: handle:set_enabled(bool), handle:is_enabled()
        _ = luaL_newmetatable(L, Self.handleMeta)
        hd_newtable(L)
        setBuiltin("set_enabled", .setEnabled)
        setBuiltin("is_enabled", .isEnabled)
        lua_setfield(L, -2, "__index")
        hd_pop(L, 1)

        hd_newtable(L)
        lua_setfield(L, hd_registryindex(), Self.loadedKey)

        // hl
        hd_newtable(L)
        setBuiltin("config", .config)
        setBuiltin("bind", .bind)
        setBuiltin("window_rule", .windowRule)
        setBuiltin("workspace_rule", .workspaceRule)
        setBuiltin("define_submap", .defineSubmap)
        setBuiltin("on", .on)
        setBuiltin("exec_cmd", .execCmd)
        setBuiltin("env", .env)
        for name in ["monitor", "curve", "animation", "gesture", "device", "permission", "layer_rule", "notify"] {
            setBuiltin(name, .ignored, "hl.\(name)")
        }
        lua_pushstring(L, "\(BuildInfo.current.version)-hyprdarwin")
        lua_setfield(L, -2, "version")

        // hl.dsp
        hd_newtable(L)
        for name in ["exec_cmd", "exec_raw", "exit", "reload_config", "submap", "layout", "focus", "no_op",
                     "pass", "send_shortcut", "send_key_state", "dpms", "event", "global",
                     "force_renderer_reload", "force_idle", "release_input_capture"] {
            setBuiltin(name, .dispatcher, name)
        }
        let namespaces: [String: [String]] = [
            "window": ["close", "kill", "signal", "float", "fullscreen", "fullscreen_state", "pseudo", "move",
                       "swap", "center", "cycle_next", "tag", "clear_tags", "toggle_swallow", "pin",
                       "bring_to_top", "alter_zorder", "set_prop", "deny_from_group", "drag", "resize"],
            "workspace": ["rename", "change_id", "move", "swap_monitors", "toggle_special"],
            "group": [],
            "cursor": [],
        ]
        for (namespace, members) in namespaces.sorted(by: { $0.key < $1.key }) {
            hd_newtable(L)
            for member in members { setBuiltin(member, .dispatcher, "\(namespace).\(member)") }
            namespaceIndexMetatable(prefix: "\(namespace).")
            lua_setfield(L, -2, namespace)
        }
        namespaceIndexMetatable(prefix: "")
        lua_setfield(L, -2, "dsp")

        // unknown hl.* names resolve to a function that warns
        hd_newtable(L)
        setBuiltin("__index", .hlIndex)
        _ = lua_setmetatable(L, -2)
        lua_setglobal(L, "hl")

        // hd: hyprdarwin-only extras; nil on Hyprland, so `if hd then` gates them
        hd_newtable(L)
        setBuiltin("config", .macConfig)
        hd_newtable(L)
        setBuiltin("cycle_layout", .dispatcher, "hd.cycle_layout")
        setBuiltin("retile", .dispatcher, "hd.retile")
        namespaceIndexMetatable(prefix: "hd.")
        lua_setfield(L, -2, "dsp")
        lua_pushstring(L, BuildInfo.current.version)
        lua_setfield(L, -2, "version")
        lua_setglobal(L, "hd")

        pushBuiltin(.print)
        lua_setglobal(L, "print")
        pushBuiltin(.require)
        lua_setglobal(L, "require")
    }

    /// Give the table on top a metatable whose __index makes unknown members
    /// dispatcher constructors named prefix + member (they warn and no-op).
    private func namespaceIndexMetatable(prefix: String) {
        hd_newtable(L)
        setBuiltin("__index", .dispatcherNamespaceIndex, prefix)
        _ = lua_setmetatable(L, -2)
    }

    // MARK: - Running

    /// Run the config file. Returns the Lua error message on failure.
    func run(path: String) -> String? {
        files.append(path)
        hd_set_budget(L, Self.loadBudget)
        defer { hd_set_budget(L, 0) }
        let chunk = "@" + displayName(for: path)
        guard hd_load_file(L, path, chunk) == LUA_OK else {
            defer { hd_pop(L, 1) }
            return Lua.string(L, -1) ?? "cannot load \(path)"
        }
        guard hd_pcall(L, 0, 0) == LUA_OK else {
            defer { hd_pop(L, 1) }
            return Lua.string(L, -1) ?? "error while running \(path)"
        }
        return nil
    }

    /// Run config source text (tests, and the default config check).
    func run(source: String, chunkName: String) -> String? {
        hd_set_budget(L, Self.loadBudget)
        defer { hd_set_budget(L, 0) }
        let status = source.withCString { pointer in
            hd_load_buffer(L, pointer, strlen(pointer), "=" + chunkName)
        }
        guard status == LUA_OK else {
            defer { hd_pop(L, 1) }
            return Lua.string(L, -1) ?? "cannot load \(chunkName)"
        }
        guard hd_pcall(L, 0, 0) == LUA_OK else {
            defer { hd_pop(L, 1) }
            return Lua.string(L, -1) ?? "error while running \(chunkName)"
        }
        return nil
    }

    func displayName(for path: String) -> String {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    func finishLoading() {
        isLoading = false
        for bind in builder.config.binds {
            if case .dispatcher(.submap(let name)) = bind.action, name != "reset", !name.isEmpty,
               !builder.config.submaps.contains(name) {
                builder.note(.warning, "hl.bind \"\(bind.combo)\": submap \"\(name)\" is never defined with hl.define_submap")
            }
        }
    }

    /// Call a Lua function a bind holds.
    public func call(function ref: Int) -> CallOutcome {
        hd_getref(L, Int32(ref))
        return invokeTop(name: "bind")
    }

    /// Run the hl.on callbacks registered for `event`.
    public func fire(_ event: ConfigEvent) -> CallOutcome {
        var outcome = CallOutcome()
        for name in event.names {
            for ref in callbacks[name] ?? [] {
                hd_getref(L, ref)
                let single = invokeTop(name: name)
                outcome.actions += single.actions
                outcome.messages += single.messages
                if let error = single.error { outcome.error = error }
            }
        }
        return outcome
    }

    /// Run Lua sent by `hyprdarwinctl dispatch`, in this config's state:
    /// an expression whose value is a dispatcher (a function value is called
    /// first, and what it returns dispatched), or statements that call
    /// dispatchers themselves (`hl.dsp.focus({ workspace = 2 })()`).
    public func evaluate(_ code: String) -> CallOutcome {
        pendingActions.removeAll()
        callMessages.removeAll()
        hd_set_budget(L, Self.callbackBudget)
        let top = lua_gettop(L)
        defer {
            lua_settop(L, top)
            hd_set_budget(L, 0)
            pendingActions.removeAll()
            callMessages.removeAll()
        }
        func load(_ text: String) -> Int32 {
            text.withCString { hd_load_buffer(L, $0, strlen($0), "=hyprdarwinctl") }
        }
        var outcome = CallOutcome()
        func finish(error: String? = nil) -> CallOutcome {
            outcome.error = error
            outcome.actions = error == nil ? pendingActions : []
            outcome.messages = callMessages
            return outcome
        }
        // an expression first, as the Lua REPL does; else statements
        if load("return " + code) != LUA_OK {
            hd_pop(L, 1)
            guard load(code) == LUA_OK else { return finish(error: Lua.string(L, -1) ?? "cannot parse the Lua") }
        }
        guard hd_pcall(L, 0, 1) == LUA_OK else { return finish(error: Lua.string(L, -1) ?? "error while running the Lua") }
        if lua_type(L, -1) == LUA_TFUNCTION {
            guard hd_pcall(L, 0, 1) == LUA_OK else { return finish(error: Lua.string(L, -1) ?? "error while running the Lua") }
        }
        switch lua_type(L, -1) {
        case LUA_TNIL:
            break
        case LUA_TTABLE where Lua.dispatcherIndex(L, -1).map { $0 < dispatchers.count } == true:
            pendingActions.append(.dispatch(dispatchers[Lua.dispatcherIndex(L, -1)!]))
        default:
            let type = String(cString: lua_typename(L, lua_type(L, -1)))
            return finish(error: "expected an hl.dsp.* dispatcher, got a \(type) value")
        }
        if pendingActions.isEmpty {
            return finish(error: "nothing was dispatched (expected an hl.dsp.* dispatcher, e.g. hl.dsp.focus({ workspace = 2 }))")
        }
        return finish()
    }

    private func invokeTop(name: String) -> CallOutcome {
        pendingActions.removeAll()
        callMessages.removeAll()
        hd_set_budget(L, Self.callbackBudget)
        defer { hd_set_budget(L, 0) }
        var outcome = CallOutcome()
        if hd_pcall(L, 0, 0) != LUA_OK {
            outcome.error = Lua.string(L, -1) ?? "error in \(name) callback"
            hd_pop(L, 1)
        }
        outcome.actions = pendingActions
        outcome.messages = callMessages
        pendingActions.removeAll()
        callMessages.removeAll()
        return outcome
    }

    // MARK: - Builtins

    private func raise(_ message: String) -> Int32 {
        lua_pushstring(L, message)
        return HD_RAISE
    }

    private func note(_ severity: ConfigMessage.Severity, _ text: String) {
        if isLoading {
            builder.note(severity, text)
        } else {
            callMessages.append(ConfigMessage(severity, text))
        }
    }

    private func upvalueName() -> String {
        Lua.string(L, hd_upvalueindex(2)) ?? ""
    }

    private func onlyWhileLoading(_ name: String) -> Int32? {
        guard isLoading else { return raise("\(name) can only be called while the config loads") }
        return nil
    }

    fileprivate func handle(_: OpaquePointer, _ id: Int32) -> Int32 {
        guard let builtin = Builtin(rawValue: id) else { return 0 }
        let location = Lua.location(L)
        do {
            switch builtin {
            case .config:
                if let error = onlyWhileLoading("hl.config") { return error }
                guard let table = Lua.read(L, 1).tableValue else { return raise("hl.config expects a table") }
                try builder.applyOptions(table, location: location)
                return 0

            case .macConfig:
                if let error = onlyWhileLoading("hd.config") { return error }
                guard let table = Lua.read(L, 1).tableValue else { return raise("hd.config expects a table") }
                try builder.applyMacOptions(table, location: location)
                return 0

            case .bind:
                if let error = onlyWhileLoading("hl.bind") { return error }
                guard let keys = Lua.string(L, 1) else { return raise("hl.bind expects a key string first, e.g. \"HYPR + Q\"") }
                let action: BindAction
                switch lua_type(L, 2) {
                case LUA_TFUNCTION:
                    lua_pushvalue(L, 2)
                    action = .luaFunction(Int(hd_ref(L)))
                case LUA_TTABLE:
                    guard let index = Lua.dispatcherIndex(L, 2), index < dispatchers.count else {
                        return raise("hl.bind \"\(keys)\": the action must be an hl.dsp.* dispatcher or a function")
                    }
                    action = .dispatcher(dispatchers[index])
                default:
                    return raise("hl.bind \"\(keys)\": the action must be an hl.dsp.* dispatcher or a function")
                }
                let flags = Lua.read(L, 3).tableValue ?? LuaTable()
                let index = try builder.addBind(keys: keys, action: action, flags: flags, location: location)
                if let index { builder.config.binds[index].submap = currentSubmap }
                pushHandle(kind: "bind", handles: &bindHandles, index: index)
                return 1

            case .windowRule:
                if let error = onlyWhileLoading("hl.window_rule") { return error }
                guard let table = Lua.read(L, 1).tableValue else { return raise("hl.window_rule expects a table") }
                let index = try builder.addWindowRule(table, location: location)
                pushHandle(kind: "rule", handles: &ruleHandles, index: index)
                return 1

            case .workspaceRule:
                if let error = onlyWhileLoading("hl.workspace_rule") { return error }
                guard let table = Lua.read(L, 1).tableValue else { return raise("hl.workspace_rule expects a table") }
                try builder.addWorkspaceRule(table, location: location)
                return 0

            case .defineSubmap:
                if let error = onlyWhileLoading("hl.define_submap") { return error }
                guard let name = Lua.string(L, 1), !name.isEmpty, name != "reset" else {
                    return raise("hl.define_submap expects a submap name (not \"reset\")")
                }
                guard currentSubmap == nil else { return raise("hl.define_submap cannot be nested") }
                let body = lua_gettop(L)
                guard lua_type(L, body) == LUA_TFUNCTION, body >= 2 else {
                    return raise("hl.define_submap(\"\(name)\", function() ... end) expects a function")
                }
                builder.config.submaps.insert(name)
                currentSubmap = name
                lua_pushvalue(L, body)
                let status = hd_pcall(L, 0, 0)
                currentSubmap = nil
                return status == LUA_OK ? 0 : HD_RAISE_RAW

            case .on:
                guard let event = Lua.string(L, 1), lua_type(L, 2) == LUA_TFUNCTION else {
                    return raise("hl.on expects an event name and a function")
                }
                let known = ConfigEvent.start.names + ConfigEvent.shutdown.names
                guard known.contains(event) else {
                    note(.warning, "\(location) hl.on: event \"\(event)\" is not supported yet (supported: \(known.joined(separator: ", ")))")
                    return 0
                }
                lua_pushvalue(L, 2)
                callbacks[event, default: []].append(hd_ref(L))
                return 0

            case .execCmd:
                guard let command = Lua.read(L, 1).text, !command.isEmpty else { return raise("hl.exec_cmd expects a command string") }
                pendingActions.append(.dispatch(.exec(command)))
                return 0

            case .env:
                if let error = onlyWhileLoading("hl.env") { return error }
                guard let name = Lua.string(L, 1), let value = Lua.read(L, 2).text else {
                    return raise("hl.env expects a name and a value")
                }
                builder.config.environment[name] = value
                return 0

            case .ignored:
                note(.info, "\(upvalueName()) is ignored on macOS")
                return 0

            case .unknownFunction:
                note(.warning, "\(location) \(upvalueName()) is not part of hyprdarwin's hl API (ignored)")
                return 0

            case .hlIndex:
                guard let key = Lua.string(L, 2) else { return 0 }
                pushBuiltin(.unknownFunction, "hl.\(key)")
                return 1

            case .dispatcherNamespaceIndex:
                guard let key = Lua.string(L, 2) else { return 0 }
                pushBuiltin(.dispatcher, upvalueName() + key)
                return 1

            case .print:
                let count = lua_gettop(L)
                var parts: [String] = []
                if count > 0 {
                    for index in 1...count {
                        let value = Lua.read(L, index)
                        parts.append(value.text ?? (value == .none ? "nil" : (value.bool.map(String.init) ?? value.typeName)))
                    }
                }
                note(.info, "print: \(parts.joined(separator: "\t"))")
                return 0

            case .require:
                return requireModule(location: location)

            case .dispatcher:
                let name = upvalueName()
                let count = lua_gettop(L)
                let args = count == 0 ? [] : (1...count).map { Lua.read(L, $0) }
                switch DispatcherParser.parse(name, args) {
                case .failure(let error):
                    return raise(error.message)
                case .success(let outcome):
                    for text in outcome.notes {
                        note(outcome.isUnknown ? .warning : .info, "\(location) \(text)")
                    }
                    pushDispatcher(outcome.dispatcher)
                    return 1
                }

            case .callDispatcher:
                guard let index = Lua.dispatcherIndex(L, 1), index < dispatchers.count else { return 0 }
                pendingActions.append(.dispatch(dispatchers[index]))
                return 0

            case .setEnabled, .isEnabled:
                guard lua_type(L, 1) == LUA_TTABLE else { return raise("use handle:set_enabled(true|false)") }
                lua_pushstring(L, Self.handleKey)
                lua_rawget(L, 1)
                let handle = Int(lua_tointegerx(L, -1, nil))
                hd_pop(L, 1)
                lua_pushstring(L, Self.handleKindKey)
                lua_rawget(L, 1)
                let kind = Lua.string(L, -1) ?? ""
                hd_pop(L, 1)
                let target = kind == "rule"
                    ? (handle < ruleHandles.count ? ruleHandles[handle] : nil)
                    : (handle < bindHandles.count ? bindHandles[handle] : nil)
                if builtin == .isEnabled {
                    guard let target else {
                        lua_pushboolean(L, 0)
                        return 1
                    }
                    let enabled = kind == "rule" ? builder.config.windowRules[target].enabled : builder.config.binds[target].enabled
                    lua_pushboolean(L, enabled ? 1 : 0)
                    return 1
                }
                guard let enabled = Lua.read(L, 2).bool else { return raise("set_enabled expects true or false") }
                guard let target else { return 0 }
                if kind == "rule" {
                    builder.config.windowRules[target].enabled = enabled
                    if !isLoading { pendingActions.append(.setWindowRuleEnabled(target, enabled)) }
                } else {
                    builder.config.binds[target].enabled = enabled
                    if !isLoading { pendingActions.append(.setBindEnabled(target, enabled)) }
                }
                return 0
            }
        } catch let error as ConfigError {
            lua_pushstring(L, error.message)
            return HD_RAISE_RAW
        } catch {
            return raise("\(error)")
        }
    }

    private func pushDispatcher(_ dispatcher: Dispatcher) {
        dispatchers.append(dispatcher)
        lua_createtable(L, 0, 1)
        lua_pushinteger(L, lua_Integer(dispatchers.count - 1))
        lua_setfield(L, -2, Self.dispatcherKey)
        luaL_setmetatable(L, Self.dispatcherMeta)
    }

    private func pushHandle(kind: String, handles: inout [Int?], index: Int?) {
        handles.append(index)
        lua_createtable(L, 0, 2)
        lua_pushinteger(L, lua_Integer(handles.count - 1))
        lua_setfield(L, -2, Self.handleKey)
        lua_pushstring(L, kind)
        lua_setfield(L, -2, Self.handleKindKey)
        luaL_setmetatable(L, Self.handleMeta)
    }

    /// require("name"): name.lua or name/init.lua under the config directory
    /// (dots are path separators), or an absolute / ~ path. Modules run once
    /// per load in the same sandbox and are cached.
    private func requireModule(location: String) -> Int32 {
        guard let name = Lua.string(L, 1), !name.isEmpty else { return raise("require expects a module name") }
        lua_getfield(L, hd_registryindex(), Self.loadedKey)
        let loaded = lua_gettop(L)
        lua_pushstring(L, name)
        lua_rawget(L, loaded)
        if lua_type(L, -1) != LUA_TNIL {
            return 1
        }
        hd_pop(L, 1)

        let candidates: [String]
        if name.hasPrefix("/") || name.hasPrefix("~") {
            let expanded = (name as NSString).expandingTildeInPath
            candidates = expanded.hasSuffix(".lua") ? [expanded] : [expanded + ".lua", expanded + "/init.lua"]
        } else {
            let relative = name.hasSuffix(".lua") ? String(name.dropLast(4)) : name
            let base = (directory as NSString).appendingPathComponent(relative.replacingOccurrences(of: ".", with: "/"))
            candidates = [base + ".lua", (base as NSString).appendingPathComponent("init.lua")]
        }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return raise("module \"\(name)\" not found (looked for \(candidates.map(displayName(for:)).joined(separator: ", ")))")
        }
        if !files.contains(path) { files.append(path) }
        guard hd_load_file(L, path, "@" + displayName(for: path)) == LUA_OK else { return HD_RAISE_RAW }
        guard hd_pcall(L, 0, 1) == LUA_OK else { return HD_RAISE_RAW }
        if lua_type(L, -1) == LUA_TNIL {
            hd_pop(L, 1)
            lua_pushboolean(L, 1)
        }
        lua_pushstring(L, name)
        lua_pushvalue(L, -2)
        lua_rawset(L, loaded)
        return 1
    }
}
