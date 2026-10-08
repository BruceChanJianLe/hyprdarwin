import Darwin
import Foundation
import Synchronization

/// The request socket. Each client is read and answered on its own queue
/// with short timeouts; only the request handler runs on `handlerQueue`
/// (the app's main thread), and it never waits on a client. A client that
/// connects and sends nothing, or stops reading its reply, costs a
/// background thread for a second or two, never a stalled tiling.
public final class RequestServer: Sendable {
    /// Answer `request` by calling the reply closure exactly once, from any
    /// thread. A reply dropped without being called closes the connection.
    public typealias Handler = @Sendable (IPCRequest, _ reply: @escaping @Sendable (String) -> Void) -> Void

    public struct Limits: Sendable {
        /// How long a client has to start sending, and how long it may then
        /// pause before what it sent counts as the whole request.
        public var firstByte = 2.0
        public var idle = 0.1
        public var requestBytes = 64 * 1024
        /// A reply that cannot be written in this long is dropped.
        public var send = 2.0
        /// Connections being served at once; more are closed straight away.
        public var concurrentClients = 32

        public init() {}
    }

    public let path: String
    private let limits: Limits
    private let handlerQueue: DispatchQueue
    private let handler: Handler
    private let state = Mutex(State())

    private struct State: ~Copyable {
        var source: DispatchSourceRead?
        var active = 0
    }

    public init(path: String, limits: Limits = Limits(), handlerQueue: DispatchQueue = .main, handler: @escaping Handler) {
        self.path = path
        self.limits = limits
        self.handlerQueue = handlerQueue
        self.handler = handler
    }

    public func start() throws {
        let listener = try UnixSocket.listen(path: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "hyprdarwin.ipc.accept"))
        source.setEventHandler { [weak self] in self?.acceptAll(listener) }
        source.setCancelHandler { close(listener) }
        state.withLock { $0.source = source }
        source.resume()
    }

    public func stop() {
        let source = state.withLock { state -> DispatchSourceRead? in
            defer { state.source = nil }
            return state.source
        }
        source?.cancel()
        unlink(path)
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.prepare(fd)
            let admitted = state.withLock { state -> Bool in
                guard state.active < limits.concurrentClients else { return false }
                state.active += 1
                return true
            }
            guard admitted else {
                close(fd)
                continue
            }
            let connection = Connection(fd: fd) { [weak self] in
                self?.state.withLock { $0.active -= 1 }
            }
            DispatchQueue(label: "hyprdarwin.ipc.client").async { [limits, handlerQueue, handler] in
                guard let data = UnixSocket.readRequest(fd, firstByteTimeout: limits.firstByte, idleTimeout: limits.idle, limit: limits.requestBytes),
                      let request = IPCRequest(parsing: String(decoding: data, as: UTF8.self)) else {
                    connection.finish(nil)
                    return
                }
                handlerQueue.async {
                    handler(request) { reply in
                        DispatchQueue.global(qos: .userInitiated).async {
                            UnixSocket.setTimeout(fd, SO_SNDTIMEO, seconds: limits.send)
                            connection.finish(Data(reply.utf8))
                        }
                    }
                }
            }
        }
    }

    /// Owns one accepted descriptor: closed after the reply, or when the
    /// last reference goes away without one.
    private final class Connection: Sendable {
        private let fd: Int32
        private let onClose: @Sendable () -> Void
        private let closed = Mutex(false)

        init(fd: Int32, onClose: @escaping @Sendable () -> Void) {
            self.fd = fd
            self.onClose = onClose
        }

        func finish(_ reply: Data?) {
            let first = closed.withLock { closed -> Bool in
                defer { closed = true }
                return !closed
            }
            guard first else { return }
            if let reply { _ = UnixSocket.writeAll(fd, reply) }
            close(fd)
            onClose()
        }

        deinit { finish(nil) }
    }
}

/// The event socket: every client gets each `EVENT>>DATA` line. Lines are
/// written on the client's own queue with a send timeout; a client that
/// falls too far behind or stops reading is disconnected, so publishing
/// never blocks the caller.
public final class EventServer: Sendable {
    public struct Limits: Sendable {
        /// Publish calls queued for one client before it is dropped.
        public var pendingBatches = 1024
        public var send = 1.0

        public init() {}
    }

    public let path: String
    private let limits: Limits
    private let state = Mutex(State())

    private struct State: ~Copyable {
        var source: DispatchSourceRead?
        var clients: [ObjectIdentifier: Client] = [:]
    }

    public init(path: String, limits: Limits = Limits()) {
        self.path = path
        self.limits = limits
    }

    public var clientCount: Int { state.withLock { $0.clients.count } }

    public func start() throws {
        let listener = try UnixSocket.listen(path: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: DispatchQueue(label: "hyprdarwin.ipc.events.accept"))
        source.setEventHandler { [weak self] in self?.acceptAll(listener) }
        source.setCancelHandler { close(listener) }
        state.withLock { $0.source = source }
        source.resume()
    }

    public func stop() {
        let (source, clients) = state.withLock { state -> (DispatchSourceRead?, [Client]) in
            defer {
                state.source = nil
                state.clients = [:]
            }
            return (state.source, Array(state.clients.values))
        }
        source?.cancel()
        for client in clients { client.disconnect() }
        unlink(path)
    }

    /// Send `lines` (without newlines) to every client.
    public func publish(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        let clients = state.withLock { Array($0.clients.values) }
        for client in clients where !client.send(data, limit: limits.pendingBatches) {
            remove(client)
        }
    }

    private func remove(_ client: Client) {
        _ = state.withLock { $0.clients.removeValue(forKey: ObjectIdentifier(client)) }
        client.disconnect()
    }

    private func acceptAll(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            UnixSocket.prepare(fd)
            UnixSocket.setTimeout(fd, SO_SNDTIMEO, seconds: limits.send)
            let client = Client(fd: fd)
            // started before anyone can publish to it, so disconnect always
            // finds its read source to cancel (which closes the descriptor)
            client.start { [weak self, weak client] in
                guard let self, let client else { return }
                self.remove(client)
            }
            state.withLock { $0.clients[ObjectIdentifier(client)] = client }
        }
    }

    /// One subscriber. Its writes, its hang-up detection and the closing of
    /// its descriptor all run on its serial queue, so the descriptor is
    /// never written after it was closed.
    private final class Client: Sendable {
        private let fd: Int32
        private let queue = DispatchQueue(label: "hyprdarwin.ipc.events.client")
        private let state = Mutex(ClientState())

        private struct ClientState: ~Copyable {
            var pending = 0
            var closed = false
            var source: DispatchSourceRead?
        }

        init(fd: Int32) {
            self.fd = fd
        }

        /// Watch for the client hanging up (whatever it sends is ignored).
        func start(onHangUp: @escaping @Sendable () -> Void) {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [fd] in
                let chunk = UnixSocket.readChunk(fd)
                if chunk?.isEmpty ?? true { onHangUp() }
            }
            source.setCancelHandler { [fd] in close(fd) }
            state.withLock { $0.source = source }
            source.resume()
        }

        /// Queue `data`; false when the client is closed, fell behind or
        /// failed a write and should be dropped.
        func send(_ data: Data, limit: Int) -> Bool {
            let accepted = state.withLock { state -> Bool in
                guard !state.closed, state.pending < limit else { return false }
                state.pending += 1
                return true
            }
            guard accepted else { return false }
            queue.async { [self] in
                let open = state.withLock { state -> Bool in
                    state.pending -= 1
                    return !state.closed
                }
                guard open, UnixSocket.writeAll(fd, data) else {
                    disconnect()
                    return
                }
            }
            return true
        }

        func disconnect() {
            let source = state.withLock { state -> DispatchSourceRead? in
                guard !state.closed else { return nil }
                state.closed = true
                defer { state.source = nil }
                return state.source
            }
            source?.cancel()
        }
    }
}
