import Darwin
import Foundation
import HyprdarwinIPC

// hyprdarwinctl: hyprctl for hyprdarwin. Sends one request to the request
// socket and prints the reply, or streams the event socket.

let usage = """
    usage: hyprdarwinctl [-j] [-i INSTANCE] <command> [arguments]

    Queries:
      clients          every managed window
      activewindow     the focused window
      workspaces       every workspace
      activeworkspace  the focused monitor's workspace
      monitors         every display
      binds            every key binding
      workspacerules   every hl.workspace_rule
      configerrors     the last load's errors, warnings and notes
      version          the running hyprdarwin's version

    Actions:
      dispatch <lua>   run a dispatcher, e.g.
                       hyprdarwinctl dispatch 'hl.dsp.focus({ workspace = 3 })'
      reload           reload the config

    Local:
      instances        list running hyprdarwin instances
      events           print event socket lines (EVENT>>DATA) until interrupted

    Options:
      -j, --json       JSON output
      -i, --instance   a signature or index from `instances` (default: the
                       one in $\(IPCPaths.signatureVariable) if running, else the newest)
      -h, --help       this help
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("hyprdarwinctl: \(message)\n".utf8))
    exit(code)
}

func write(_ text: String) {
    FileHandle.standardOutput.write(Data((text.hasSuffix("\n") || text.isEmpty ? text : text + "\n").utf8))
}

var json = false
var explicitInstance: String?
var rest: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.first {
    // options end at the command; everything after belongs to it
    guard rest.isEmpty else { break }
    arguments = arguments.dropFirst()
    switch argument {
    case "-j", "--json":
        json = true
    case "-i", "--instance":
        guard let value = arguments.first else { fail("\(argument) needs a value", code: 2) }
        explicitInstance = value
        arguments = arguments.dropFirst()
    case "-h", "--help", "help":
        write(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") && argument.count > 1 { fail("unknown option \(argument) (see hyprdarwinctl --help)", code: 2) }
        rest.append(argument)
    }
}
rest += arguments
// `hyprdarwinctl clients -j` works too; a dispatch's Lua is left alone
if rest.first != "dispatch", rest.contains(where: { $0 == "-j" || $0 == "--json" }) {
    json = true
    rest.removeAll { $0 == "-j" || $0 == "--json" }
}

guard let command = rest.first else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
let commandArguments = rest.dropFirst().joined(separator: " ")
let environmentSignature = ProcessInfo.processInfo.environment[IPCPaths.signatureVariable]

switch command {
case "instances":
    let live = IPCPaths.instances().filter(\.isLive)
    if json {
        let objects = live.map { instance -> [String: Any] in
            ["instance": instance.signature, "pid": instance.pid.map(Int.init) ?? 0, "time": instance.startTime ?? 0,
             "socket": instance.requestSocket, "eventSocket": instance.eventSocket]
        }
        let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        write(objects.isEmpty ? "[]" : String(decoding: data, as: UTF8.self))
    } else if live.isEmpty {
        fail("hyprdarwin is not running (no live instance in \(IPCPaths.defaultBase))")
    } else {
        for (index, instance) in live.enumerated() {
            write("instance \(index) \(instance.signature):\n\tpid: \(instance.pid.map(String.init) ?? "?")\n\tsocket: \(instance.requestSocket)\n")
        }
    }
    exit(0)
default:
    break
}

let instance: IPCInstance
switch IPCPaths.resolve(explicit: explicitInstance, environment: environmentSignature) {
case .success(let found): instance = found
case .failure(let error): fail(error.description)
}

if command == "events" || command == "listen" {
    setvbuf(stdout, nil, _IOLBF, 0)
    do {
        try IPCClient.listen(to: instance) { line in
            print(line)
            return true
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

let request = IPCRequest(command: command, arguments: commandArguments, json: json)
let reply: String
do {
    reply = try IPCClient.send(request, to: instance)
} catch {
    fail("\(instance.signature): \(error)")
}
if IPCReply.isFailure(reply, to: request) {
    fail(reply == IPCReply.unknownRequest ? "unknown command \"\(command)\" (see hyprdarwinctl --help)" : String(reply.dropFirst("error: ".count)))
}
write(reply)
