import Foundation
import HerdrKit

/// The app's Unix socket for `ghr`: NDJSON requests, any number per
/// connection. Only the current user can connect (mode 0600).
final class ControlServer: @unchecked Sendable {
    typealias Handler = @MainActor (_ method: String, _ params: JSONValue) async throws -> JSONValue

    struct Failure: Error {
        let code: String
        let message: String
    }

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1

    init(path: String = GhostHerdrControl.socketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(code: "socket", message: String(cString: strerror(errno))) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw Failure(code: "bind", message: "\(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                var reply = respond(to: Data(line))
                reply.append(0x0A)
                let ok = reply.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { return false }
                        offset += n
                    }
                    return true
                }
                if !ok { return }
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Runs the handler on the main actor and waits for it.
    private func respond(to line: Data) -> Data {
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: line),
              let method = request["method"]?.stringValue
        else {
            return Self.encode(id: .null, error: Failure(code: "invalid_request", message: "expected {id, method, params}"))
        }
        let id = request["id"] ?? .null
        let params = request["params"] ?? [:]
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let handler = handler
        Task { @MainActor in
            do {
                box.result = .success(try await handler(method, params))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case let .success(value): return Self.encode(id: id, result: value)
        case let .failure(error as Failure): return Self.encode(id: id, error: error)
        case let .failure(error): return Self.encode(id: id, error: Failure(code: "failed", message: String(describing: error)))
        case nil: return Self.encode(id: id, error: Failure(code: "failed", message: "no result"))
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<JSONValue, Error>?
    }

    private static func encode(id: JSONValue, result: JSONValue) -> Data {
        Data(JSONValue.object(["id": id, "result": result]).jsonString.utf8)
    }

    private static func encode(id: JSONValue, error: Failure) -> Data {
        let body: JSONValue = ["code": .string(error.code), "message": .string(error.message)]
        return Data(JSONValue.object(["id": id, "error": body]).jsonString.utf8)
    }
}
