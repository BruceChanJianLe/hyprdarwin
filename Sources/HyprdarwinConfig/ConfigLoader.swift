import Foundation
import HyprdarwinCore

/// The result of evaluating the config once.
public struct ConfigLoadResult {
    /// nil when the config was rejected (see `messages` for the error).
    public var config: Config?
    /// Keep this alive while `config` is active: Lua binds and hl.on live in it.
    public var runtime: LuaConfigRuntime?
    public var messages: [ConfigMessage]
    /// exec_cmd calls and dispatchers the config ran at load time; run them
    /// only once the config has been applied.
    public var actions: [RuntimeAction]
    /// The main file plus every module it required.
    public var files: [String]

    public var errors: [ConfigMessage] { messages.filter { $0.severity == .error } }
    public var succeeded: Bool { config != nil }
}

public enum ConfigLoader {
    /// Evaluate the config file at `path` in a fresh sandboxed Lua state.
    public static func load(path: String) -> ConfigLoadResult {
        let directory = (path as NSString).deletingLastPathComponent
        let runtime = LuaConfigRuntime(directory: directory)
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigLoadResult(config: nil, runtime: nil, messages: [ConfigMessage(.error, "config file \(path) does not exist")], actions: [], files: [path])
        }
        let error = runtime.run(path: path)
        return finish(runtime, error: error)
    }

    /// Evaluate config source text; `directory` is where require() looks.
    public static func load(source: String, chunkName: String = "hyprdarwin.lua", directory: String = NSTemporaryDirectory()) -> ConfigLoadResult {
        let runtime = LuaConfigRuntime(directory: directory)
        let error = runtime.run(source: source, chunkName: chunkName)
        return finish(runtime, error: error)
    }

    private static func finish(_ runtime: LuaConfigRuntime, error: String?) -> ConfigLoadResult {
        if let error {
            var messages = runtime.builder.messages.filter { $0.severity != .info }
            messages.insert(ConfigMessage(.error, error), at: 0)
            return ConfigLoadResult(config: nil, runtime: nil, messages: messages, actions: [], files: runtime.files)
        }
        runtime.finishLoading()
        let actions = runtime.pendingActions
        runtime.pendingActions.removeAll()
        return ConfigLoadResult(config: runtime.config, runtime: runtime, messages: runtime.builder.messages, actions: actions, files: runtime.files)
    }
}

public enum ConfigPaths {
    /// The config file to use: $HYPRDARWIN_CONFIG, then
    /// $XDG_CONFIG_HOME/hypr/hyprdarwin.lua, then ~/.config/hypr/hyprdarwin.lua;
    /// the first that exists wins. When none exists the explicit
    /// $HYPRDARWIN_CONFIG path (or else the first XDG candidate) is where
    /// the default config gets written.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var candidates: [String] = []
        if let explicit = environment["HYPRDARWIN_CONFIG"], !explicit.isEmpty {
            candidates.append((explicit as NSString).expandingTildeInPath)
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(((xdg as NSString).expandingTildeInPath as NSString).appendingPathComponent("hypr/hyprdarwin.lua"))
        }
        candidates.append((home as NSString).appendingPathComponent(".config/hypr/hyprdarwin.lua"))
        return candidates.first(where: exists) ?? candidates[0]
    }
}
