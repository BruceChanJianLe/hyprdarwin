import Darwin
import Foundation

public struct SocketError: Error, Equatable, CustomStringConvertible {
    public var operation: String
    public var code: Int32

    init(_ operation: String, _ code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Thin helpers over BSD Unix-domain stream sockets. Every descriptor is
/// close-on-exec (commands hyprdarwin runs must not inherit them) and never
/// raises SIGPIPE.
enum UnixSocket {
    /// sun_path holds 104 bytes including the terminating NUL.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { throw SocketError("socket path too long (\(bytes.count) > \(maxPathLength) bytes)", ENAMETOOLONG) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        prepare(fd)
        return fd
    }

    /// Close-on-exec, no SIGPIPE, blocking. Accepted sockets inherit the
    /// listener's O_NONBLOCK on Darwin, so it is cleared here too.
    static func prepare(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }

    /// A non-blocking listening socket at `path` (replacing a stale file),
    /// readable and writable by the user only.
    static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = try makeSocket()
        do {
            let bound = try withAddress(path) { Darwin.bind(fd, $0, $1) }
            guard bound == 0 else { throw SocketError("bind \(path)") }
            chmod(path, 0o600)
            guard Darwin.listen(fd, 64) == 0 else { throw SocketError("listen \(path)") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    static func connect(path: String) throws -> Int32 {
        let fd = try makeSocket()
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let error = SocketError("connect \(path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// SO_SNDTIMEO / SO_RCVTIMEO: a blocking write or read gives up after `seconds`.
    static func setTimeout(_ fd: Int32, _ option: Int32, seconds: Double) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Write everything, or give up on the first error or send timeout.
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Wait up to `seconds` for `fd` to become readable (data or EOF).
    static func waitReadable(_ fd: Int32, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return false }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32((left * 1000).rounded(.up)))
            if ready > 0 { return true }
            if ready == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// One read: the bytes, an empty Data at EOF, nil on error.
    static func readChunk(_ fd: Int32, maximum: Int = 16384) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = Darwin.read(fd, &buffer, maximum)
            if count >= 0 { return Data(buffer[0..<count]) }
            if errno != EINTR { return nil }
        }
    }

    /// A request: everything up to EOF, or what arrived before the sender
    /// went quiet (clients that write and wait without closing their side,
    /// as Hyprland's protocol allows). nil when nothing arrived in time.
    static func readRequest(_ fd: Int32, firstByteTimeout: Double, idleTimeout: Double, limit: Int) -> Data? {
        var request = Data()
        var timeout = firstByteTimeout
        while request.count < limit, waitReadable(fd, seconds: timeout) {
            guard let chunk = readChunk(fd), !chunk.isEmpty else { break }
            request.append(chunk)
            timeout = idleTimeout
        }
        return request.isEmpty ? nil : request.prefix(limit)
    }
}
