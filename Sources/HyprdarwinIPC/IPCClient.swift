import Darwin
import Foundation

/// Talks to a hyprdarwin instance's sockets (hyprdarwinctl, tests).
public enum IPCClient {
    /// Send one request and return the whole reply.
    public static func send(_ request: IPCRequest, to instance: IPCInstance, timeout: Double = 10) throws -> String {
        try send(raw: request.encoded, to: instance.requestSocket, timeout: timeout)
    }

    /// Send `text` as is to the request socket at `path`.
    public static func send(raw text: String, to path: String, timeout: Double = 10) throws -> String {
        let fd = try UnixSocket.connect(path: path)
        defer { close(fd) }
        UnixSocket.setTimeout(fd, SO_SNDTIMEO, seconds: timeout)
        guard UnixSocket.writeAll(fd, Data(text.utf8)) else { throw SocketError("send") }
        // end of request: the server answers without waiting for more
        shutdown(fd, SHUT_WR)
        var reply = Data()
        while true {
            guard UnixSocket.waitReadable(fd, seconds: timeout) else { throw SocketError("no reply within \(Int(timeout)) s", ETIMEDOUT) }
            guard let chunk = UnixSocket.readChunk(fd) else { throw SocketError("receive") }
            if chunk.isEmpty { break }
            reply.append(chunk)
        }
        return String(decoding: reply, as: UTF8.self)
    }

    /// Call `onLine` with each event line (without its newline) until the
    /// instance closes the socket or `onLine` returns false.
    public static func listen(to instance: IPCInstance, onLine: (String) -> Bool) throws {
        let fd = try UnixSocket.connect(path: instance.eventSocket)
        defer { close(fd) }
        var buffer = Data()
        while let chunk = UnixSocket.readChunk(fd), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard onLine(line) else { return }
            }
        }
    }
}
