import Darwin
import Foundation
import Synchronization
import Testing
@testable import HyprdarwinIPC

/// A fresh base directory with short paths (sun_path holds 103 bytes).
private func makeBase() throws -> String {
    let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("hdipc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return base
}

private func makeInstance(_ base: String, signature: String = IPCPaths.newSignature()) throws -> IPCInstance {
    let instance = IPCInstance(signature: signature, base: base)
    try FileManager.default.createDirectory(atPath: instance.directory, withIntermediateDirectories: true)
    return instance
}

/// Replies "<json flag>:<command>:<arguments>" on its own queue.
private func echoServer(_ path: String, limits: RequestServer.Limits = RequestServer.Limits()) -> RequestServer {
    RequestServer(path: path, limits: limits, handlerQueue: DispatchQueue(label: "test.handler")) { request, reply in
        reply("\(request.json ? "j" : "-"):\(request.command):\(request.arguments)")
    }
}

private func waitUntil(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

@Suite struct IPCRequestTests {
    @Test func parsesHyprctlRequests() {
        #expect(IPCRequest(parsing: "j/clients") == IPCRequest(command: "clients", json: true))
        #expect(IPCRequest(parsing: "/clients") == IPCRequest(command: "clients"))
        #expect(IPCRequest(parsing: "clients\n") == IPCRequest(command: "clients"))
        #expect(IPCRequest(parsing: "/dispatch hl.dsp.focus({ workspace = 2 })")
            == IPCRequest(command: "dispatch", arguments: "hl.dsp.focus({ workspace = 2 })"))
        // a "/" inside the arguments is not a flag separator
        #expect(IPCRequest(parsing: "dispatch hl.dsp.exec_cmd('open /Applications')")
            == IPCRequest(command: "dispatch", arguments: "hl.dsp.exec_cmd('open /Applications')"))
        #expect(IPCRequest(parsing: "   ") == nil)
        #expect(IPCRequest(parsing: "j/") == nil)
    }

    @Test func encodesTheWireForm() {
        #expect(IPCRequest(command: "clients", json: true).encoded == "j/clients")
        #expect(IPCRequest(command: "dispatch", arguments: "x()").encoded == "/dispatch x()")
        let request = IPCRequest(command: "dispatch", arguments: "hl.dsp.focus({ workspace = 2 })")
        #expect(IPCRequest(parsing: request.encoded) == request)
    }

    @Test func failureReplies() {
        #expect(IPCReply.isFailure(IPCReply.error("nope")))
        #expect(IPCReply.isFailure(IPCReply.unknownRequest))
        #expect(!IPCReply.isFailure(IPCReply.ok))
        #expect(!IPCReply.isFailure("Window 1a -> error: something"))
    }
}

@Suite struct IPCPathsTests {
    @Test func signatureSortsByStartTime() {
        let instance = IPCInstance(signature: IPCPaths.newSignature(pid: 42, date: Date(timeIntervalSince1970: 1_700_000_000)), base: "/b")
        #expect(instance.signature == "1700000000_42")
        #expect(instance.startTime == 1_700_000_000)
        #expect(instance.pid == 42)
        #expect(instance.requestSocket == "/b/1700000000_42/.socket.sock")
        #expect(instance.eventSocket == "/b/1700000000_42/.socket2.sock")
    }

    @Test func defaultBaseIsTheUserTemporaryDirectory() {
        #expect(IPCPaths.defaultBase.hasSuffix("/hyprdarwin"))
        // room for "/<signature>/.socket2.sock"
        #expect(IPCPaths.defaultBase.utf8.count + 40 <= UnixSocket.maxPathLength)
    }

    @Test func resolvesLiveInstancesAndCleansUpDeadOnes() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        #expect(IPCPaths.resolve(explicit: nil, environment: nil, base: base) == .failure(.notRunning(base)))

        let old = try makeInstance(base, signature: "1000_1")
        let new = try makeInstance(base, signature: "2000_2")
        let dead = try makeInstance(base, signature: "3000_3")
        let oldServer = echoServer(old.requestSocket)
        let newServer = echoServer(new.requestSocket)
        try oldServer.start()
        try newServer.start()
        defer {
            oldServer.stop()
            newServer.stop()
        }
        // a crashed instance leaves its socket file behind
        let leftover = try UnixSocket.listen(path: dead.requestSocket)
        close(leftover)

        #expect(IPCPaths.instances(base: base).map(\.signature) == ["3000_3", "2000_2", "1000_1"])
        #expect(IPCPaths.resolve(explicit: nil, environment: nil, base: base) == .success(new))
        #expect(IPCPaths.resolve(explicit: nil, environment: "1000_1", base: base) == .success(old))
        // a stale signature in the environment falls back to the newest
        #expect(IPCPaths.resolve(explicit: nil, environment: "3000_3", base: base) == .success(new))
        #expect(IPCPaths.resolve(explicit: "1", environment: nil, base: base) == .success(old))
        #expect(IPCPaths.resolve(explicit: "1000_1", environment: "2000_2", base: base) == .success(old))
        #expect(IPCPaths.resolve(explicit: "3000_3", environment: nil, base: base) == .failure(.noSuchInstance("3000_3")))

        IPCPaths.removeStaleInstances(base: base)
        #expect(!FileManager.default.fileExists(atPath: dead.directory))
        #expect(FileManager.default.fileExists(atPath: new.requestSocket))
    }
}

@Suite struct RequestServerTests {
    @Test func answersRequestsAndRemovesItsSocket() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        let server = echoServer(instance.requestSocket)
        try server.start()
        #expect(try IPCClient.send(IPCRequest(command: "clients", json: true), to: instance) == "j:clients:")
        #expect(try IPCClient.send(IPCRequest(command: "dispatch", arguments: "a(1)"), to: instance) == "-:dispatch:a(1)")
        // socket files are private to the user
        let attributes = try FileManager.default.attributesOfItem(atPath: instance.requestSocket)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: instance.requestSocket))
        #expect(throws: SocketError.self) { try IPCClient.send(IPCRequest(command: "clients"), to: instance) }
    }

    /// Hyprland-style clients write the request and wait without closing
    /// their side; the reply comes once they go quiet.
    @Test func answersClientsThatDoNotHalfClose() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        let server = echoServer(instance.requestSocket)
        try server.start()
        defer { server.stop() }
        let fd = try UnixSocket.connect(path: instance.requestSocket)
        defer { close(fd) }
        #expect(UnixSocket.writeAll(fd, Data("j/monitors".utf8)))
        #expect(UnixSocket.waitReadable(fd, seconds: 3))
        #expect(UnixSocket.readChunk(fd).map { String(decoding: $0, as: UTF8.self) } == "j:monitors:")
    }

    /// A client that connects and never sends (or never reads) must not
    /// hold up anyone else.
    @Test func aStuckClientDoesNotBlockOthers() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        var limits = RequestServer.Limits()
        limits.firstByte = 5
        let server = echoServer(instance.requestSocket, limits: limits)
        try server.start()
        defer { server.stop() }
        let stuck = try (0..<4).map { _ in try UnixSocket.connect(path: instance.requestSocket) }
        defer { stuck.forEach { close($0) } }
        let start = Date()
        #expect(try IPCClient.send(IPCRequest(command: "version"), to: instance) == "-:version:")
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func aSilentClientIsDisconnected() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        var limits = RequestServer.Limits()
        limits.firstByte = 0.2
        let server = echoServer(instance.requestSocket, limits: limits)
        try server.start()
        defer { server.stop() }
        let fd = try UnixSocket.connect(path: instance.requestSocket)
        defer { close(fd) }
        #expect(UnixSocket.waitReadable(fd, seconds: 3))
        #expect(UnixSocket.readChunk(fd)?.isEmpty == true)
    }

    @Test func aDroppedReplyClosesTheConnection() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        let server = RequestServer(path: instance.requestSocket, handlerQueue: DispatchQueue(label: "test.handler")) { _, _ in }
        try server.start()
        defer { server.stop() }
        #expect(try IPCClient.send(IPCRequest(command: "clients"), to: instance, timeout: 3) == "")
    }
}

@Suite struct EventServerTests {
    @Test func everyClientGetsEveryLine() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        let server = EventServer(path: instance.eventSocket)
        try server.start()
        defer { server.stop() }

        let received = Mutex<[Int: [String]]>([:])
        let group = DispatchGroup()
        for listener in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                try? IPCClient.listen(to: instance) { line in
                    let count = received.withLock { state -> Int in
                        state[listener, default: []].append(line)
                        return state[listener]!.count
                    }
                    return count < 3
                }
            }
        }
        #expect(waitUntil { server.clientCount == 2 })
        server.publish(["workspace>>2", "workspacev2>>2,2"])
        server.publish(["configreloaded>>"])
        #expect(group.wait(timeout: .now() + 3) == .success)
        let lines = received.withLock { $0 }
        #expect(lines[0] == ["workspace>>2", "workspacev2>>2,2", "configreloaded>>"])
        #expect(lines[1] == lines[0])
        // both hung up after their third line
        #expect(waitUntil { server.clientCount == 0 })
    }

    /// A client that never reads is dropped once it falls behind, and
    /// publishing never blocks meanwhile.
    @Test func aClientThatStopsReadingIsDropped() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let instance = try makeInstance(base)
        var limits = EventServer.Limits()
        limits.pendingBatches = 8
        limits.send = 0.2
        let server = EventServer(path: instance.eventSocket, limits: limits)
        try server.start()
        defer { server.stop() }
        let fd = try UnixSocket.connect(path: instance.eventSocket)
        defer { close(fd) }
        #expect(waitUntil { server.clientCount == 1 })
        let line = String(repeating: "x", count: 4096)
        let start = Date()
        for _ in 0..<2000 { server.publish(["windowtitlev2>>1,\(line)"]) }
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(waitUntil { server.clientCount == 0 })
    }
}
