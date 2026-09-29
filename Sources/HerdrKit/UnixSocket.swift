import Foundation

public enum HerdrError: Error, CustomStringConvertible, Sendable {
    case connect(path: String, errno: Int32)
    case io(String)
    case server(code: String, message: String)
    case decode(String)

    public var description: String {
        switch self {
        case let .connect(path, err): "cannot connect to \(path): \(String(cString: strerror(err)))"
        case let .io(msg): "socket I/O failed: \(msg)"
        case let .server(code, message): "herdr error \(code): \(message)"
        case let .decode(msg): "unexpected herdr response: \(msg)"
        }
    }
}

/// A blocking Unix-domain stream socket that reads newline-delimited lines.
/// Every call blocks, so callers run it off the main thread.
final class UnixSocket: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    private var closed = false

    init(path: String, timeout: TimeInterval?) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.connect(path: path, errno: errno) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if let timeout {
            var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            Darwin.close(fd)
            throw HerdrError.io("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw HerdrError.connect(path: path, errno: err)
        }
    }

    deinit { close() }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Unblocks a reader stuck in `readLine` on another thread.
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    func writeLine(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HerdrError.io("write: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    /// Returns the next line without its newline, or `nil` at end of stream.
    func readLine() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { return buffer.isEmpty ? nil : { defer { buffer.removeAll() }; return buffer }() }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw HerdrError.io("timed out") }
                throw HerdrError.io("read: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
