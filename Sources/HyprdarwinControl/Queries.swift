import Foundation
import HyprdarwinConfig
import HyprdarwinCore
import HyprdarwinIPC

/// The request socket's read-only queries.
public enum Query: String, CaseIterable, Sendable {
    case clients, activewindow, workspaces, activeworkspace, monitors, binds, workspacerules, configerrors, version
}

/// What a query reads: the model, the active config (with runtime bind
/// toggles), the last load's messages and the build.
public struct QueryContext {
    public var model: WindowManager
    public var config: Config
    public var messages: [ConfigMessage]
    public var build: BuildInfo

    public init(model: WindowManager, config: Config, messages: [ConfigMessage], build: BuildInfo) {
        self.model = model
        self.config = config
        self.messages = messages
        self.build = build
    }
}

extension Query {
    /// The reply: hyprctl-style text, or pretty JSON with `json`.
    public func reply(json: Bool, context: QueryContext) -> String {
        let model = context.model
        switch self {
        case .clients:
            let clients = model.windows.values
                .sorted { ($0.workspace, $0.id) < ($1.workspace, $1.id) }
                .map { ClientObject($0, model: model) }
            return json ? Self.encode(clients) : clients.map(Self.text).joined()
        case .activewindow:
            guard let window = model.focusedWindow.flatMap({ model.windows[$0] }) else { return json ? "{}" : "Invalid\n" }
            let client = ClientObject(window, model: model)
            return json ? Self.encode(client) : Self.text(client)
        case .workspaces:
            let workspaces = model.workspaces.values.sorted { $0.id < $1.id }.map { WorkspaceObject($0, model: model) }
            return json ? Self.encode(workspaces) : workspaces.map(Self.text).joined()
        case .activeworkspace:
            guard let monitor = model.focusedMonitor, let id = model.monitorStates[monitor.id]?.activeWorkspace,
                  let workspace = model.workspaces[id] else { return json ? "{}" : "Invalid\n" }
            let object = WorkspaceObject(workspace, model: model)
            return json ? Self.encode(object) : Self.text(object)
        case .monitors:
            let monitors = model.monitors.spatiallySorted.map { MonitorObject($0, model: model) }
            return json ? Self.encode(monitors) : monitors.map(Self.text).joined()
        case .binds:
            let binds = context.config.binds.map(BindObject.init)
            return json ? Self.encode(binds) : binds.map(Self.text).joined()
        case .workspacerules:
            let rules = context.config.workspaceRules.map(WorkspaceRuleObject.init)
            return json ? Self.encode(rules) : rules.map(Self.text).joined()
        case .configerrors:
            let messages = context.messages.map { ConfigMessageObject(severity: $0.severity.rawValue, text: $0.text) }
            if json { return Self.encode(messages) }
            return messages.map { "\($0.severity): \($0.text)\n" }.joined()
        case .version:
            let build = context.build
            let object = VersionObject(version: build.version, commit: build.commit ?? "", build: build.build ?? "",
                                       origin: build.origin ?? "", description: build.description)
            return json ? Self.encode(object) : "hyprdarwin \(build)\n"
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        // JSONEncoder pretty-prints an empty array over three lines
        if let array = value as? [Any], array.isEmpty { return "[]\n" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Text, after hyprctl's

    static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func text(_ client: ClientObject) -> String {
        """
        Window \(client.address.dropFirst(2)) -> \(client.title):
        \tmapped: \(flag(client.mapped))
        \thidden: \(flag(client.hidden))
        \tat: \(client.at[0]),\(client.at[1])
        \tsize: \(client.size[0]),\(client.size[1])
        \tworkspace: \(client.workspace.id) (\(client.workspace.name))
        \tfloating: \(flag(client.floating))
        \tmonitor: \(client.monitor)
        \tclass: \(client.class)
        \ttitle: \(client.title)
        \tinitialClass: \(client.initialClass)
        \tinitialTitle: \(client.initialTitle)
        \tappName: \(client.appName)
        \tpid: \(client.pid)
        \tfullscreen: \(client.fullscreen)
        \tfocusHistoryID: \(client.focusHistoryID)
        \ttags: \(client.tags.joined(separator: ", "))
        \trole: \(client.role)
        \tsubrole: \(client.subrole)
        \tminSize: \(client.minSize[0]),\(client.minSize[1])


        """
    }

    static func text(_ workspace: WorkspaceObject) -> String {
        """
        workspace ID \(workspace.id) (\(workspace.name)) on monitor \(workspace.monitor):
        \tmonitorID: \(workspace.monitorID)
        \twindows: \(workspace.windows)
        \thasfullscreen: \(flag(workspace.hasfullscreen))
        \tlastwindow: \(workspace.lastwindow)
        \tlastwindowtitle: \(workspace.lastwindowtitle)
        \tispersistent: \(flag(workspace.ispersistent))
        \ttiledLayout: \(workspace.tiledLayout)
        \tvisible: \(flag(workspace.visible))


        """
    }

    static func text(_ monitor: MonitorObject) -> String {
        """
        Monitor \(monitor.name) (ID \(monitor.id)):
        \t\(monitor.width)x\(monitor.height) at \(monitor.x)x\(monitor.y)
        \tdescription: \(monitor.description)
        \tdisplayID: \(monitor.displayID)
        \tactive workspace: \(monitor.activeWorkspace.id) (\(monitor.activeWorkspace.name))
        \tspecial workspace: \(monitor.specialWorkspace.id) (\(monitor.specialWorkspace.name))
        \treserved: \(monitor.reserved.map(String.init).joined(separator: " "))
        \tfocused: \(monitor.focused ? "yes" : "no")


        """
    }

    static func text(_ bind: BindObject) -> String {
        """
        bind
        \tmodifiers: \(bind.modifiers.joined(separator: " + "))
        \tkey: \(bind.key)
        \tkeycode: \(bind.keycode)
        \tsubmap: \(bind.submap)
        \trepeat: \(flag(bind.repeating))
        \trelease: \(flag(bind.release))
        \tenabled: \(flag(bind.enabled))
        \tdescription: \(bind.description)
        \tdispatcher: \(bind.dispatcher)


        """
    }

    static func text(_ rule: WorkspaceRuleObject) -> String {
        func sides(_ value: [Double]?) -> String { value.map { $0.map(ConfigReport.number).joined(separator: " ") } ?? "<unset>" }
        return """
        Workspace rule \(rule.workspaceString):
        \tmonitor: \(rule.monitor ?? "<unset>")
        \tdefault: \(rule.default.map(flag) ?? "<unset>")
        \tpersistent: \(rule.persistent.map(flag) ?? "<unset>")
        \tlayout: \(rule.layout ?? "<unset>")
        \tgapsIn: \(sides(rule.gapsIn))
        \tgapsOut: \(sides(rule.gapsOut))


        """
    }
}

/// What a request asks for.
public enum ControlCommand: Equatable, Sendable {
    case query(Query, json: Bool)
    /// Lua to evaluate in the config's state (`hyprdarwinctl dispatch`).
    case dispatch(String)
    case reload
    case unknown(String)

    public init(_ request: IPCRequest) {
        switch request.command {
        case "dispatch": self = .dispatch(request.arguments)
        case "reload": self = .reload
        default:
            if let query = Query(rawValue: request.command) {
                self = .query(query, json: request.json)
            } else {
                self = .unknown(request.command)
            }
        }
    }
}
