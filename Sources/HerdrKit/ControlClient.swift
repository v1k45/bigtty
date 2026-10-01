import Foundation

/// bigtty's own control socket, which `btty` (and agents) use to drive
/// the app: browser panes, file views, notifications. Same framing as
/// herdr's API: one NDJSON request, one NDJSON response.
public enum BigttyControl {
    /// `BIGTTY_SOCKET`, else `~/Library/Application Support/bigtty/control.sock`.
    public static var socketPath: String {
        if let path = ProcessInfo.processInfo.environment["BIGTTY_SOCKET"], !path.isEmpty { return path }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("bigtty/control.sock").path
    }
}

public struct ControlClient: Sendable {
    public let socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = BigttyControl.socketPath, timeout: TimeInterval = 60) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// Sends one request and returns its `result`. Blocking; for CLIs.
    public func call(_ method: String, _ params: [String: JSONValue] = [:]) throws -> JSONValue {
        let socket = try UnixSocket(path: socketPath, timeout: timeout)
        defer { socket.close() }
        let request: JSONValue = ["id": "1", "method": .string(method), "params": .object(params)]
        try socket.writeLine(JSONEncoder().encode(request))
        guard let line = try socket.readLine() else { throw HerdrError.io("bigtty closed the connection") }
        let reply = try JSONDecoder().decode(JSONValue.self, from: line)
        if let error = reply["error"] {
            throw HerdrError.server(
                code: error["code"]?.stringValue ?? "error",
                message: error["message"]?.stringValue ?? ""
            )
        }
        return reply["result"] ?? .null
    }
}

extension JSONValue {
    /// Compact JSON text.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }

    /// Converts a Foundation value (from JSONSerialization or WebKit) to JSON.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as Bool where type(of: v) == Bool.self: self = .bool(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) } else { self = .number(v.doubleValue) }
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as JSONValue: self = v
        default: self = .string(String(describing: value!))
        }
    }

    /// The Foundation equivalent, for passing into WebKit.
    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(b): b
        case let .number(n): n
        case let .string(s): s
        case let .array(a): a.map(\.anyValue)
        case let .object(o): o.mapValues(\.anyValue)
        }
    }

    public var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        if case let .string(s) = self { return Int(s) }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(n) = self { return n }
        if case let .string(s) = self { return Double(s) }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }
}
