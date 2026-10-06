import Foundation
import Testing
@testable import HyprdarwinConfig
@testable import HyprdarwinCore

private func load(_ source: String, directory: String = NSTemporaryDirectory()) -> ConfigLoadResult {
    ConfigLoader.load(source: source, directory: directory)
}

private func warnings(_ result: ConfigLoadResult) -> [String] {
    result.messages.filter { $0.severity == .warning }.map(\.text)
}

private func infos(_ result: ConfigLoadResult) -> [String] {
    result.messages.filter { $0.severity == .info }.map(\.text)
}

@Suite struct DefaultConfigTests {
    @Test func defaultConfigLoadsCleanly() throws {
        let result = load(DefaultConfig.text)
        #expect(result.messages.isEmpty, "\(result.messages)")
        let config = try #require(result.config)
        #expect(config.layout == .dwindle)
        #expect(config.gapsOut == Insets(all: 12))
        #expect(config.layoutOptions.dwindle.preserveSplit)
        #expect(config.submaps == ["resize"])
        #expect(config.windowRules.count == 5)
        // workspace binds 1-10 plus the move variants
        let workspaceBinds = config.binds.filter {
            if case .dispatcher(.focusWorkspace(.id(.numbered), _)) = $0.action { return true }
            return false
        }
        #expect(workspaceBinds.count == 10)
        let ten = try #require(workspaceBinds.first { $0.combo.keyName == "0" })
        #expect(ten.action == .dispatcher(.focusWorkspace(.id(.numbered(10)), onCurrentMonitor: false)))
        #expect(ten.combo.modifiers == [.hypr])
        let resizeBinds = config.binds.filter { $0.submap == "resize" }
        #expect(resizeBinds.count == 6)
        #expect(resizeBinds.first?.repeating == true)
        #expect(config.binds.allSatisfy { $0.submap == nil || $0.submap == "resize" })
        #expect(config.focusOnOpen == false)
        #expect(config.activeBorder == Config().activeBorder, "the Hyprland gradient")
        #expect(config.activeBorder.colors == ["rgba(33ccffee)", "rgba(00ff99ee)"].map { Color(parsing: $0)! })
        #expect(config.activeBorder.angle == 45)
        #expect(config.inactiveBorder == nil, "unfocused windows get no border")

        func action(_ keys: String) -> BindAction? {
            let combo = try! KeyCombo.parse(keys).get()
            return config.binds.first { $0.combo == combo && $0.submap == nil }?.action
        }
        #expect(action("HYPR + h") == .dispatcher(.focusDirection(.left)))
        #expect(action("HYPR + j") == .dispatcher(.focusDirection(.down)))
        #expect(action("HYPR + k") == .dispatcher(.focusDirection(.up)))
        #expect(action("HYPR + l") == .dispatcher(.focusDirection(.right)))
        #expect(action("HYPR + SHIFT + l") == .dispatcher(.swapDirection(.right)))
        #expect(action("HYPR + left") == .dispatcher(.focusDirection(.left)))
        #expect(action("HYPR + SPACE") == .dispatcher(.layoutMessage("togglesplit")))
        #expect(action("HYPR + SHIFT + SPACE") == .dispatcher(.cycleLayout(reverse: false)))
        #expect(action("HYPR + F") == .dispatcher(.fullscreen(.maximized, .toggle)))
        #expect(action("HYPR + R") == .dispatcher(.retile))
        #expect(action("HYPR + SHIFT + R") == .dispatcher(.submap("resize")))
        #expect(action("HYPR + CTRL + R") == .dispatcher(.reload))
        #expect(action("HYPR + N") == .dispatcher(.focusWorkspace(.existing(1), onCurrentMonitor: false)))
        #expect(action("HYPR + P") == .dispatcher(.focusWorkspace(.existing(-1), onCurrentMonitor: false)))
        #expect(action("HYPR + bracketright") == .dispatcher(.focusWorkspace(.relativeOnMonitor(1), onCurrentMonitor: false)))
        #expect(action("HYPR + bracketleft") == .dispatcher(.focusWorkspace(.relativeOnMonitor(-1), onCurrentMonitor: false)))
        #expect(action("HYPR + TAB") == nil, "HYPR is Caps Lock, next to Tab: no default Tab bind")
        #expect(action("HYPR + SHIFT + V") == .dispatcher(.cycleWindows(.floating, reverse: false)))
        let combos = config.binds.filter { $0.submap == nil }.map(\.combo)
        #expect(Set(combos).count == combos.count, "no two global binds share a key")
    }

    @Test func focusOnOpenAndUnmanagedApps() throws {
        let config = try #require(load("""
        hl.config({ misc = { focus_on_open = true } })
        hd.config({ unmanaged_apps = { "com.mitchellh.ghostty" } })
        hl.bind("HYPR + C", hd.dsp.cycle_layout())
        hl.bind("HYPR + R", hd.dsp.retile())
        hl.bind("HYPR + B", hd.dsp.cycle_layout({ direction = "prev" }))
        hl.bind("HYPR + T", hl.dsp.window.cycle_next({ floating = true }))
        hl.bind("HYPR + Y", hl.dsp.window.cycle_next({ tiled = true, prev = true }))
        hl.window_rule({ match = { class = "brave" }, min_size = "800 50%" })
        hl.workspace_rule({ workspace = "3", layout = "main-vertical-mirrored" })
        hl.config({ general = { layout = "even-vertical" } })
        """).config)
        #expect(config.binds[2].action == .dispatcher(.cycleLayout(reverse: true)))
        #expect(config.binds[3].action == .dispatcher(.cycleWindows(.floating, reverse: false)))
        #expect(config.binds[4].action == .dispatcher(.cycleWindows(.tiled, reverse: true)))
        #expect(config.windowRules[0].effects.minSize == "800 50%")
        #expect(config.workspaceRule(for: .numbered(3))?.layout == .mainVerticalMirrored)
        #expect(config.layout == .evenVertical)
        #expect(load("hl.bind(\"HYPR + C\", hd.dsp.cycle_layout({ direction = \"previous\" }))").config == nil)
        #expect(load("hl.bind(\"HYPR + C\", hd.dsp.cycle_layout({ direction = \"up\" }))").config == nil)
        #expect(config.binds[1].action == .dispatcher(.retile))
        #expect(config.focusOnOpen)
        #expect(config.unmanagedApps == ["com.mitchellh.ghostty"])
        #expect(config.binds[0].action == .dispatcher(.cycleLayout(reverse: false)))
        #expect(load("hd.config({ unmanaged_apps = \"com.mitchellh.ghostty\" })").config == nil)
        #expect(load("hl.config({ misc = { focus_on_open = \"sometimes\" } })").config == nil)
        let unknown = load("hl.bind(\"HYPR + C\", hd.dsp.frobnicate())")
        #expect(unknown.messages.contains { $0.text.contains("hd.dsp.frobnicate is not a known dispatcher") })
    }
}

@Suite struct OptionTests {
    @Test func generalLayoutAndGaps() throws {
        let result = load("""
        hl.config({
          general = { layout = "master", gaps_in = "1 2 3 4", gaps_out = 7, border_size = 3,
                      col = { active_border = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
                              inactive_border = "rgba(595959aa)" } },
          dwindle = { force_split = 2, default_split_ratio = 1.2 },
          master = { mfact = 0.6, new_status = "master", orientation = "top", new_on_top = true },
          input = { follow_mouse = 0 },
          cursor = { no_warps = true },
          misc = { disable_autoreload = true },
        })
        """)
        let config = try #require(result.config, "\(result.messages)")
        #expect(result.messages.isEmpty)
        #expect(config.layout == .master)
        #expect(config.gapsIn == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(config.gapsOut == Insets(all: 7))
        #expect(config.borderSize == 3)
        #expect(config.activeBorder.colors.count == 2)
        #expect(config.activeBorder.angle == 45)
        #expect(config.layoutOptions.dwindle.forceSplit == 2)
        #expect(config.layoutOptions.dwindle.defaultSplitRatio == 1.2)
        #expect(config.layoutOptions.master.mfact == 0.6)
        #expect(config.layoutOptions.master.newStatus == .master)
        #expect(config.layoutOptions.master.orientation == .top)
        #expect(config.followMouse == 0)
        #expect(config.noWarps)
        #expect(config.disableAutoreload)
    }

    @Test func multipleCallsMerge() throws {
        let config = try #require(load("""
        hl.config({ general = { gaps_in = 1 } })
        hl.config({ general = { gaps_out = 2 } })
        """).config)
        #expect(config.gapsIn == Insets(all: 1))
        #expect(config.gapsOut == Insets(all: 2))
    }

    @Test func typeErrorsRejectTheConfigWithALocation() {
        let result = load("""
        -- line 1
        hl.config({ general = { gaps_in = { 1 } } })
        """)
        #expect(result.config == nil)
        #expect(result.errors.first?.text.hasPrefix("hyprdarwin.lua:2:") == true, "\(result.errors)")
        #expect(result.errors.first?.text.contains("general.gaps_in") == true)
    }

    @Test func unknownOptionsWarnAndIgnoredOptionsInform() throws {
        let result = load("""
        hl.config({
          general = { gap_in = 4, allow_tearing = false },
          decoration = { rounding = 10, blur = { enabled = true } },
          animations = { enabled = true },
          input = { kb_layout = "us", touchpad = { natural_scroll = true } },
          misc = { force_default_wallpaper = -1 },
          frobnicate = { x = 1 },
        })
        """)
        #expect(result.config != nil)
        #expect(warnings(result) == ["hyprdarwin.lua:1: unknown option frobnicate.x", "hyprdarwin.lua:1: unknown option general.gap_in"])
        #expect(infos(result).contains("decoration.* options are ignored on macOS"))
        #expect(infos(result).contains("general.allow_tearing is ignored on macOS"))
        #expect(infos(result).contains("input.touchpad.* options are ignored on macOS"))
        #expect(infos(result).contains("misc.force_default_wallpaper is ignored on macOS"))
    }

    @Test func macOptionsAndHdGate() throws {
        let config = try #require(load("""
        if hd then hd.config({ hypr_key = "f18", hide_corner = "bottom-left" }) end
        """).config)
        #expect(config.hyprKey == .f18)
        #expect(config.hideCorner == .bottomLeft)
        #expect(load("hd.config({ hypr_key = \"fn\" })").config == nil)
    }

    @Test func hyprlandOnlyCallsAreAccepted() throws {
        let result = load("""
        hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
        hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
        hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
        hl.env("XCURSOR_SIZE", "24")
        hl.frobnicate()
        """)
        let config = try #require(result.config)
        #expect(config.environment == ["XCURSOR_SIZE": "24"])
        #expect(infos(result).contains("hl.monitor is ignored on macOS"))
        #expect(warnings(result) == ["hyprdarwin.lua:5: hl.frobnicate is not part of hyprdarwin's hl API (ignored)"])
    }
}

@Suite struct BindTests {
    @Test func bindsDispatchersFlagsAndHandles() throws {
        let result = load("""
        local mod = "HYPR"
        local close = hl.bind(mod .. " + Q", hl.dsp.window.close(), { description = "Close" })
        close:set_enabled(false)
        hl.bind("CMD + SHIFT + 3", hl.dsp.window.move({ workspace = 3, follow = false }), { release = true })
        hl.bind("SUPER + L", hl.dsp.layout("swapwithmaster"), { locked = true })
        hl.bind("HYPR + mouse:272", hl.dsp.window.drag(), { mouse = true })
        """)
        let config = try #require(result.config, "\(result.messages)")
        #expect(config.binds.count == 3)
        #expect(config.binds[0].enabled == false)
        #expect(config.binds[0].description == "Close")
        #expect(config.binds[1].release)
        #expect(config.binds[1].action == .dispatcher(.moveToWorkspace(.id(.numbered(3)), follow: false)))
        #expect(config.binds[2].combo.modifiers == [.command])
        #expect(infos(result).contains { $0.contains("locked") })
        #expect(warnings(result).contains { $0.contains("mouse binds are not supported yet") })
    }

    @Test func badBindsFail() {
        #expect(load("hl.bind(\"HYPR + NOPE\", hl.dsp.exit())").errors.first?.text.contains("unknown key \"NOPE\"") == true)
        #expect(load("hl.bind(\"HYPR + Q\", \"exit\")").config == nil)
        #expect(load("hl.dsp.focus({ direction = \"sideways\" })").errors.first?.text.contains("invalid direction") == true)
    }

    @Test func dispatcherShapes() throws {
        let config = try #require(load("""
        hl.bind("HYPR + 1", hl.dsp.focus({ workspace = "e+1" }))
        hl.bind("HYPR + 2", hl.dsp.focus({ monitor = "l" }))
        hl.bind("HYPR + 3", hl.dsp.window.fullscreen({ mode = "maximized", action = "set" }))
        hl.bind("HYPR + 4", hl.dsp.window.resize({ x = 40, y = 0, relative = true }))
        hl.bind("HYPR + 5", hl.dsp.workspace.toggle_special())
        hl.bind("HYPR + 6", hl.dsp.workspace.move({ monitor = "+1" }))
        hl.bind("HYPR + 7", hl.dsp.window.move({ x = 10, y = -10, relative = true }))
        hl.bind("HYPR + 8", hl.dsp.focus({ workspace = "special:scratch" }))
        """).config)
        #expect(config.binds.map(\.action) == [
            .dispatcher(.focusWorkspace(.existing(1), onCurrentMonitor: false)),
            .dispatcher(.focusMonitor(.direction(.left))),
            .dispatcher(.fullscreen(.maximized, .set)),
            .dispatcher(.resize(x: 40, y: 0, relative: true)),
            .dispatcher(.toggleSpecial("")),
            .dispatcher(.moveWorkspaceToMonitor(nil, .relative(1))),
            .dispatcher(.moveBy(x: 10, y: -10, relative: true)),
            .dispatcher(.focusWorkspace(.id(.special("scratch")), onCurrentMonitor: false)),
        ])
    }

    @Test func unsupportedDispatchersBecomeNoOps() throws {
        let result = load("""
        hl.bind("HYPR + P", hl.dsp.window.pseudo())
        hl.bind("HYPR + G", hl.dsp.group.toggle())
        hl.bind("HYPR + X", hl.dsp.window.frobnicate())
        """)
        let config = try #require(result.config)
        #expect(config.binds.allSatisfy { $0.action == .dispatcher(.noOp) })
        #expect(infos(result).contains { $0.contains("hl.dsp.window.pseudo") })
        #expect(infos(result).contains { $0.contains("hl.dsp.group.toggle") })
        #expect(warnings(result).contains { $0.contains("hl.dsp.window.frobnicate is not a known dispatcher") })
    }

    @Test func submapsScopeTheirBinds() throws {
        let result = load("""
        hl.bind("HYPR + R", hl.dsp.submap("resize"))
        hl.define_submap("resize", function()
          hl.bind("escape", hl.dsp.submap("reset"))
        end)
        hl.bind("HYPR + M", hl.dsp.submap("missing"))
        """)
        let config = try #require(result.config)
        #expect(config.binds.map(\.submap) == [nil, "resize", nil])
        #expect(warnings(result).contains { $0.contains("submap \"missing\" is never defined") })
    }

    @Test func luaFunctionBindsRunLater() throws {
        let result = load("""
        local count = 0
        hl.bind("HYPR + T", function()
          count = count + 1
          hl.dsp.focus({ workspace = count })()
          hl.exec_cmd("echo " .. count)
          print("pressed", count, true, nil)
        end)
        """)
        let config = try #require(result.config)
        let runtime = try #require(result.runtime)
        guard case .luaFunction(let ref) = config.binds[0].action else {
            Issue.record("expected a Lua function bind")
            return
        }
        let first = runtime.call(function: ref)
        #expect(first.error == nil)
        #expect(first.actions == [.dispatch(.focusWorkspace(.id(.numbered(1)), onCurrentMonitor: false)), .dispatch(.exec("echo 1"))])
        #expect(first.messages == [ConfigMessage(.info, "print: pressed\t1\ttrue\tnil")])
        let second = runtime.call(function: ref)
        #expect(second.actions.first == .dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false)))
    }

    @Test func callbackErrorsAndBudgetsAreContained() throws {
        let result = load("""
        hl.bind("HYPR + E", function() error("boom") end)
        hl.bind("HYPR + L", function() while true do end end)
        """)
        let config = try #require(result.config)
        let runtime = try #require(result.runtime)
        guard case .luaFunction(let boom) = config.binds[0].action,
              case .luaFunction(let loop) = config.binds[1].action else {
            Issue.record("expected Lua function binds")
            return
        }
        #expect(runtime.call(function: boom).error == "hyprdarwin.lua:1: boom")
        #expect(runtime.call(function: loop).error?.contains("instruction budget exceeded") == true)
    }
}

@Suite struct RuleTests {
    @Test func windowRulesParse() throws {
        let result = load(#"""
        local pip = hl.window_rule({ name = "pip", match = { title = "^Picture-in-Picture$" },
          float = true, size = "480 270", move = "monitor_w-500 40", opacity = 0.8 })
        hl.window_rule({ match = { class = "^com\\.tinyspeck\\.slackmacgap$" }, workspace = "3 silent" })
        hl.window_rule({ match = { class = "teams", title = "negative:.*Meeting.*" }, workspace = 4, tile = true })
        hl.window_rule({ match = { class = "x", xwayland = true }, float = true })
        hl.window_rule({ match = { subrole = "AXDialog" }, center = true, border_color = "rgba(ff0000ff)", dynamic = true })
        hl.window_rule({ match = { class = "red" }, border_color = 0xffff0000 })
        hl.window_rule({ match = { class = "fade" }, border_color = { colors = { "rgb(ff0000)", "rgb(0000ff)" }, angle = 90 } })
        pip:set_enabled(false)
        """#)
        let config = try #require(result.config, "\(result.messages)")
        #expect(config.windowRules.count == 6, "the xwayland rule can never match on macOS")
        #expect(config.windowRules[0].enabled == false)
        #expect(config.windowRules[0].name == "pip")
        #expect(config.windowRules[0].effects.size == "480 270")
        #expect(config.windowRules[1].effects.workspace == WorkspaceTarget(workspace: .numbered(3), silent: true))
        #expect(config.windowRules[2].effects.workspace == WorkspaceTarget(workspace: .numbered(4), silent: false))
        #expect(config.windowRules[2].effects.float == false)
        #expect(config.windowRules[2].match.title?.matches("Weekly Meeting") == false)
        #expect(config.windowRules[3].dynamic)
        let red = Color(red: 1, green: 0, blue: 0, alpha: 1)
        #expect(config.windowRules[3].effects.borderColor == BorderColor(colors: [red]))
        #expect(config.windowRules[4].effects.borderColor == BorderColor(colors: [red]))
        #expect(config.windowRules[5].effects.borderColor == BorderColor(colors: [red, Color(red: 0, green: 0, blue: 1, alpha: 1)], angle: 90))
        #expect(infos(result).contains { $0.contains("opacity is ignored on macOS") })
    }

    @Test func badRulesFail() {
        #expect(load("hl.window_rule({ float = true })").errors.first?.text.contains("match = { ... } is required") == true)
        #expect(load("hl.window_rule({ match = { class = \"(\" }, float = true })").errors.first?.text.contains("invalid regular expression") == true)
        #expect(load("hl.window_rule({ match = { class = \"a\" }, workspace = \"three\" })").config == nil)
        #expect(load("hl.window_rule({ match = { class = \"a\" }, move = \"10\" })").config == nil)
        let unknown = load("hl.window_rule({ match = { class = \"a\" }, frobnicate = true })")
        #expect(warnings(unknown).contains { $0.contains("unknown effect \"frobnicate\"") })
    }

    @Test func workspaceRulesParse() throws {
        let result = load("""
        hl.workspace_rule({ workspace = "1", monitor = "DELL U3423WE", default = true })
        hl.workspace_rule({ workspace = 5, layout = "master", gaps_in = 0, gaps_out = "10 20" })
        hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0 })
        hl.workspace_rule({ workspace = "special:scratch", persistent = true, on_created_empty = "kitty" })
        """)
        let config = try #require(result.config)
        #expect(config.workspaceRules.count == 3)
        #expect(config.workspaceRule(for: .numbered(1))?.isDefault == true)
        #expect(config.workspaceRule(for: .numbered(5))?.layout == .master)
        #expect(config.workspaceRule(for: .numbered(5))?.gapsOut == Insets(top: 10, right: 20, bottom: 10, left: 20))
        #expect(config.workspaceRule(for: .special("scratch"))?.persistent == true)
        #expect(infos(result).contains { $0.contains("w[tv1]") })
        #expect(load("hl.workspace_rule({ workspace = 2, layout = \"spiral\" })").config == nil)
    }
}

@Suite struct RuntimeTests {
    @Test func syntaxErrorsReportTheLine() {
        let result = load("hl.config({\n  general = { gaps_in = 5 }\n")
        #expect(result.config == nil)
        #expect(result.errors.first?.text.hasPrefix("hyprdarwin.lua:3:") == true, "\(result.errors)")
    }

    @Test func sandboxRemovesDangerousFunctions() throws {
        let result = load("""
        assert(io == nil, "io")
        assert(os.execute == nil, "os.execute")
        assert(os.exit == nil, "os.exit")
        assert(os.remove == nil, "os.remove")
        assert(dofile == nil, "dofile")
        assert(loadfile == nil, "loadfile")
        assert(package == nil, "package")
        assert(debug == nil, "debug")
        assert(string.dump == nil, "string.dump")
        assert(type(os.time()) == "number")
        assert(load("return 1 + 1")() == 2)
        assert(load("\\27Lua") == nil)
        """)
        #expect(result.config != nil, "\(result.messages)")
    }

    @Test func endlessLoopsHitTheBudget() {
        let result = load("while true do end")
        #expect(result.errors.first?.text.contains("instruction budget exceeded") == true)
    }

    @Test func loadTimeActionsAndStartCallbacks() throws {
        let result = load("""
        hl.exec_cmd("sketchybar")
        hl.dsp.focus({ workspace = 2 })()
        hl.on("hyprland.start", function() hl.exec_cmd("once") end)
        hl.on("window.open", function() end)
        """)
        #expect(result.actions == [.dispatch(.exec("sketchybar")), .dispatch(.focusWorkspace(.id(.numbered(2)), onCurrentMonitor: false))])
        #expect(warnings(result).contains { $0.contains("window.open") })
        let runtime = try #require(result.runtime)
        #expect(runtime.fire(.start).actions == [.dispatch(.exec("once"))])
        #expect(runtime.fire(.shutdown).actions.isEmpty)
    }

    @Test func handlesToggleRulesAtRuntime() throws {
        let result = load("""
        local rule = hl.window_rule({ match = { class = "a" }, float = true })
        hl.bind("HYPR + O", function() rule:set_enabled(not rule:is_enabled()) end)
        """)
        let config = try #require(result.config)
        let runtime = try #require(result.runtime)
        guard case .luaFunction(let ref) = config.binds[0].action else { return }
        #expect(runtime.call(function: ref).actions == [.setWindowRuleEnabled(0, false)])
        #expect(runtime.call(function: ref).actions == [.setWindowRuleEnabled(0, true)])
    }

    @Test func configOnlyCallsAreRejectedAtRuntime() throws {
        let result = load("""
        hl.bind("HYPR + O", function() hl.bind("HYPR + P", hl.dsp.exit()) end)
        """)
        let config = try #require(result.config)
        guard case .luaFunction(let ref) = config.binds[0].action else { return }
        #expect(result.runtime?.call(function: ref).error?.contains("can only be called while the config loads") == true)
    }

    @Test func requireLoadsModulesFromTheConfigDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hyprdarwin-require-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "return { gaps = 9 }".write(to: directory.appendingPathComponent("theme.lua"), atomically: true, encoding: .utf8)
        try "hl.bind('HYPR + B', hl.dsp.exit())".write(to: directory.appendingPathComponent("modules/binds.lua"), atomically: true, encoding: .utf8)
        try "error('bad module')".write(to: directory.appendingPathComponent("broken.lua"), atomically: true, encoding: .utf8)
        let main = directory.appendingPathComponent("hyprdarwin.lua")
        try """
        local theme = require("theme")
        require("modules.binds")
        require("modules.binds")
        hl.config({ general = { gaps_in = theme.gaps } })
        """.write(to: main, atomically: true, encoding: .utf8)

        let result = ConfigLoader.load(path: main.path)
        let config = try #require(result.config, "\(result.messages)")
        #expect(config.gapsIn == Insets(all: 9))
        #expect(config.binds.count == 1, "modules run once")
        #expect(result.files.count == 3)

        try "require('broken')".write(to: main, atomically: true, encoding: .utf8)
        #expect(ConfigLoader.load(path: main.path).errors.first?.text.contains("broken.lua:1: bad module") == true)
        try "require('nope')".write(to: main, atomically: true, encoding: .utf8)
        #expect(ConfigLoader.load(path: main.path).errors.first?.text.contains("module \"nope\" not found") == true)
    }

    @Test func missingFileIsAnError() {
        #expect(ConfigLoader.load(path: "/nonexistent/hyprdarwin.lua").errors.count == 1)
    }

    @Test func pathResolution() {
        let home = "/Users/me"
        #expect(ConfigPaths.resolve(environment: [:], home: home, exists: { _ in false }) == "/Users/me/.config/hypr/hyprdarwin.lua")
        #expect(ConfigPaths.resolve(environment: ["XDG_CONFIG_HOME": "/x"], home: home, exists: { _ in false }) == "/x/hypr/hyprdarwin.lua")
        #expect(ConfigPaths.resolve(environment: ["XDG_CONFIG_HOME": "/x"], home: home, exists: { $0.hasPrefix("/Users") }) == "/Users/me/.config/hypr/hyprdarwin.lua")
        #expect(ConfigPaths.resolve(environment: ["HYPRDARWIN_CONFIG": "/tmp/a.lua", "XDG_CONFIG_HOME": "/x"], home: home, exists: { _ in false }) == "/tmp/a.lua")
        #expect(ConfigPaths.resolve(environment: ["HYPRDARWIN_CONFIG": "/tmp/a.lua"], home: home, exists: { $0 == "/Users/me/.config/hypr/hyprdarwin.lua" }) == "/Users/me/.config/hypr/hyprdarwin.lua")
    }
}

@Suite struct BuildInfoTests {
    @Test func readsTheStampedInfoPlist() {
        let ci = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "57",
            "HyprdarwinCommit": "abc1234", "HyprdarwinBuildOrigin": "run",
        ])
        #expect(ci.description == "0.2.0 (abc1234, run 57)")
        let local = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "120",
            "HyprdarwinCommit": "abc1234-dirty", "HyprdarwinBuildOrigin": "local",
        ])
        #expect(local.description == "0.2.0 (abc1234-dirty, local build 120)")
        #expect(BuildInfo(infoDictionary: nil).description == "dev", "swift run: no bundle")
        #expect(BuildInfo(infoDictionary: ["CFBundleShortVersionString": "__VERSION__"]).version == "dev", "an unstamped plist")
    }

    @Test func luaSeesTheVersion() throws {
        let result = ConfigLoader.load(source: "assert(hd.version == \"\(BuildInfo.current.version)\")")
        #expect(result.config != nil, "\(result.messages)")
    }
}
