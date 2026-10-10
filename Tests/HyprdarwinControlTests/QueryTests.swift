import CoreGraphics
import Foundation
import Testing
@testable import HyprdarwinConfig
@testable import HyprdarwinControl
@testable import HyprdarwinCore
import HyprdarwinIPC

private let primary = Monitor(id: 7, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              visibleFrame: CGRect(x: 0, y: 25, width: 1000, height: 775))
private let external = Monitor(id: 9, name: "DELL", frame: CGRect(x: 1000, y: 0, width: 1200, height: 800),
                               visibleFrame: CGRect(x: 1000, y: 0, width: 1200, height: 800))

private let source = """
    hl.config({ general = { gaps_in = 0, gaps_out = 0 } })
    hl.workspace_rule({ workspace = "5", layout = "master", persistent = true, gaps_out = "1 2" })
    hl.bind("HYPR + Q", hl.dsp.window.close(), { description = "Close window" })
    hl.bind("CMD + SHIFT + left", function() end, { repeating = true })
    hl.window_rule({ name = "pip", match = { title = "^PiP$" }, float = true, size = "480 270" })
    """

private func info(_ id: WindowID, title: String = "Window", bundle: String = "com.example.app") -> WindowInfo {
    WindowInfo(id: id, pid: 100 + Int32(id), bundleID: bundle, appName: "App", title: title,
               frame: CGRect(x: 10, y: 20, width: 400, height: 300))
}

private func makeContext() throws -> QueryContext {
    let result = ConfigLoader.load(source: source)
    let config = try #require(result.config)
    let model = WindowManager(config: config)
    model.setMonitors([primary, external])
    model.addWindow(info(0x1a, title: "One"), isNew: true)
    model.addWindow(info(0x2b, title: "PiP", bundle: "com.apple.Safari"), isNew: true)
    return QueryContext(model: model, config: config, messages: [ConfigMessage(.warning, "hyprdarwin.lua:3: typo")],
                        build: BuildInfo(version: "0.3.0", commit: "abc1234", build: "57", origin: "run"))
}

private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

@Suite struct QueryTests {
    @Test func everyQueryHasAReply() throws {
        let context = try makeContext()
        for query in Query.allCases {
            #expect(!query.reply(json: false, context: context).isEmpty, "\(query)")
            let json = query.reply(json: true, context: context)
            #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil, "\(query): \(json)")
        }
    }

    @Test func clientsInJSON() throws {
        let context = try makeContext()
        let clients = try decode([ClientObject].self, Query.clients.reply(json: true, context: context))
        #expect(clients.map(\.address) == ["0x1a", "0x2b"])
        let pip = try #require(clients.last)
        #expect(pip.class == "com.apple.Safari")
        #expect(pip.title == "PiP")
        #expect(pip.floating)
        #expect(pip.workspace == WorkspaceRef(id: 1, name: "1"))
        #expect(pip.monitor == 0)
        #expect(pip.pid == 143)
        #expect(pip.hidden == false)
        #expect(pip.fullscreen == 0)
        #expect(clients.first?.at == [10, 20])
        #expect(clients.first?.size == [400, 300])
        // the key names hyprctl uses
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(Query.clients.reply(json: true, context: context).utf8)) as? [[String: Any]])
        #expect(Set(raw[0].keys).isSuperset(of: ["address", "at", "size", "workspace", "floating", "class", "title", "pid", "focusHistoryID"]))
    }

    /// A window on another macOS Space (or in native fullscreen) keeps its
    /// workspace but is not shown on it.
    @Test func awayClientIsHidden() throws {
        let context = try makeContext()
        context.model.applyListing([], away: [0x1a], previous: [0x1a], initial: false)
        let clients = try decode([ClientObject].self, Query.clients.reply(json: true, context: context))
        #expect(clients.first { $0.address == "0x1a" }?.hidden == true)
        #expect(clients.first { $0.address == "0x1a" }?.workspace == WorkspaceRef(id: 1, name: "1"))
        #expect(clients.first { $0.address == "0x2b" }?.hidden == false)
    }

    @Test func clientsAsText() throws {
        let text = Query.clients.reply(json: false, context: try makeContext())
        #expect(text.hasPrefix("Window 1a -> One:\n\tmapped: 1\n\thidden: 0\n\tat: 10,20\n\tsize: 400,300\n\tworkspace: 1 (1)\n"))
        #expect(text.contains("Window 2b -> PiP:\n"))
        #expect(text.contains("\tclass: com.apple.Safari\n"))
    }

    @Test func activeWindow() throws {
        let context = try makeContext()
        _ = context.model.focusFromCursor(0x1a)
        let client = try decode(ClientObject.self, Query.activewindow.reply(json: true, context: context))
        #expect(client.address == "0x1a")
        #expect(client.focusHistoryID == 0)
        let empty = QueryContext(model: WindowManager(), config: Config(), messages: [], build: BuildInfo(version: "dev"))
        #expect(Query.activewindow.reply(json: true, context: empty) == "{}")
        #expect(Query.activewindow.reply(json: false, context: empty) == "Invalid\n")
        #expect(Query.clients.reply(json: true, context: empty) == "[]\n")
        #expect(Query.clients.reply(json: false, context: empty) == "")
    }

    @Test func workspacesAndMonitors() throws {
        let context = try makeContext()
        _ = context.model.dispatch(.toggleSpecial("scratch"))
        let workspaces = try decode([WorkspaceObject].self, Query.workspaces.reply(json: true, context: context))
        #expect(workspaces.map(\.name) == ["1", "2", "special:scratch"])
        #expect(workspaces[0].windows == 2)
        #expect(workspaces[0].monitor == "Built-in")
        #expect(workspaces[0].tiledLayout == "dwindle")
        #expect(workspaces[1].monitorID == 1)
        #expect(workspaces[2].id == -98)

        let active = try decode(WorkspaceObject.self, Query.activeworkspace.reply(json: true, context: context))
        #expect(active.name == "1")

        let monitors = try decode([MonitorObject].self, Query.monitors.reply(json: true, context: context))
        #expect(monitors.map(\.name) == ["Built-in", "DELL"])
        #expect(monitors.map(\.id) == [0, 1])
        #expect(monitors[0].displayID == 7)
        #expect(monitors[0].reserved == [25, 0, 0, 0])
        #expect(monitors[0].focused)
        #expect(monitors[0].specialWorkspace == WorkspaceRef(id: -98, name: "special:scratch"))
        #expect(monitors[1].activeWorkspace == WorkspaceRef(id: 2, name: "2"))
        #expect(monitors[1].specialWorkspace == WorkspaceRef(id: 0, name: ""))
        #expect(Query.monitors.reply(json: false, context: context).hasPrefix("Monitor Built-in (ID 0):\n\t1000x800 at 0x0\n"))
    }

    @Test func bindsAndRules() throws {
        let context = try makeContext()
        let binds = try decode([BindObject].self, Query.binds.reply(json: true, context: context))
        #expect(binds.count == 2)
        #expect(binds[0].modifiers == ["HYPR"])
        #expect(binds[0].key == "Q")
        #expect(binds[0].description == "Close window")
        #expect(binds[0].hasDescription)
        #expect(binds[0].dispatcher == "window.close")
        #expect(binds[1].modifiers == ["CMD", "SHIFT"])
        #expect(binds[1].repeating)
        #expect(binds[1].dispatcher == "lua function")
        #expect(Query.binds.reply(json: true, context: context).contains("\"repeat\" : true"))

        let rules = try decode([WorkspaceRuleObject].self, Query.workspacerules.reply(json: true, context: context))
        #expect(rules == [WorkspaceRuleObject(workspaceString: "5", monitor: nil, default: nil, persistent: true, layout: "master",
                                              gapsIn: nil, gapsOut: [1, 2, 1, 2])])
        #expect(Query.workspacerules.reply(json: false, context: context).contains("\tgapsOut: 1 2 1 2\n"))
    }

    @Test func configErrorsAndVersion() throws {
        let context = try makeContext()
        #expect(Query.configerrors.reply(json: false, context: context) == "warning: hyprdarwin.lua:3: typo\n")
        let messages = try decode([ConfigMessageObject].self, Query.configerrors.reply(json: true, context: context))
        #expect(messages == [ConfigMessageObject(severity: "warning", text: "hyprdarwin.lua:3: typo")])
        #expect(Query.version.reply(json: false, context: context) == "hyprdarwin 0.3.0 (abc1234, run 57)\n")
        let version = try decode(VersionObject.self, Query.version.reply(json: true, context: context))
        #expect(version.version == "0.3.0")
        #expect(version.commit == "abc1234")
    }

    @Test func commandsFromRequests() {
        #expect(ControlCommand(IPCRequest(command: "clients", json: true)) == .query(.clients, json: true))
        #expect(ControlCommand(IPCRequest(command: "dispatch", arguments: "x()")) == .dispatch("x()"))
        #expect(ControlCommand(IPCRequest(command: "reload")) == .reload)
        #expect(ControlCommand(IPCRequest(command: "kill")) == .unknown("kill"))
    }
}

@Suite struct ConfigReportTests {
    @Test func optionsShowValuesAndWhatTheConfigSet() throws {
        let config = try #require(ConfigLoader.load(source: DefaultConfig.text).config)
        let report = ConfigReport(config: config)
        let options = Dictionary(uniqueKeysWithValues: report.options.map { ($0.name, $0) })
        #expect(options["general.layout"]?.value == "\"dwindle\"")
        #expect(options["general.layout"]?.isSet == false)
        #expect(options["general.gaps_out"]?.value == "12")
        #expect(options["general.gaps_out"]?.isSet == true)
        #expect(options["general.col.active_border"]?.value == "\"rgba(33ccffee) rgba(00ff99ee) 45deg\"")
        #expect(options["general.col.inactive_border"]?.value == "nil")
        #expect(options["master.mfact"]?.value == "0.55")
        #expect(options["hd.hypr_key"]?.value == "\"caps_lock\"")
        #expect(options["hd.unmanaged_apps"]?.value == "{ }")
        #expect(report.submaps == ["resize"])
        #expect(report.binds.count == config.binds.count)
        #expect(report.binds.first { $0.description == "Terminal" }?.keys == "HYPR + RETURN")
        #expect(report.binds.first { $0.submap == "resize" }?.flags == ["repeating"])
    }

    @Test func rulesInConfigSyntax() throws {
        let config = try #require(ConfigLoader.load(source: """
            hl.env("EDITOR", "nvim")
            hd.config({ unmanaged_apps = { "com.b", "com.a" } })
            hl.window_rule({ name = "pip", match = { class = "^com\\\\.apple\\\\.Safari$", title = "^PiP$" },
                float = true, size = "480 270", workspace = "3 silent", border_color = "rgb(ff0000)", no_border = true })
            hl.window_rule({ match = { float = true }, tile = true, dynamic = true })
            hl.workspace_rule({ workspace = "2", monitor = "DELL", default = true, gaps_in = 0 })
            """).config)
        let report = ConfigReport(config: config)
        #expect(report.windowRules.count == 2)
        #expect(report.windowRules[0].name == "pip")
        #expect(report.windowRules[0].match == ["class = \"^com\\\\.apple\\\\.Safari$\"", "title = \"^PiP$\""])
        #expect(report.windowRules[0].effects == ["float", "workspace = \"3 silent\"", "size = \"480 270\"", "border_color = \"rgba(ff0000ff)\"", "no_border"])
        #expect(report.windowRules[1].match == ["float = true"])
        #expect(report.windowRules[1].effects == ["tile"])
        #expect(report.windowRules[1].dynamic)
        #expect(report.workspaceRules.map(\.settings) == [["monitor = \"DELL\"", "default", "gaps_in = 0"]])
        let options = Dictionary(uniqueKeysWithValues: report.options.map { ($0.name, $0.value) })
        #expect(options["hd.unmanaged_apps"] == "{ \"com.a\", \"com.b\" }")
        #expect(options["hl.env EDITOR"] == "\"nvim\"")
    }
}
