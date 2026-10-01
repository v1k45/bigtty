import Foundation

/// One pane's terminal stream, through `herdr terminal session control`
/// (or `observe`). herdr re-renders the pane at our size and sends ANSI
/// frames; we send input, resizes and scrolls back as NDJSON on stdin.
///
/// The CLI is used instead of the binary client protocol because that
/// protocol is private and changes between herdr releases.
public final class TerminalChannel: @unchecked Sendable {
    public enum Mode: Sendable { case control, observe }

    public let terminalID: String
    public let mode: Mode
    /// Control mode only: take the pane from whoever holds it. Without it,
    /// herdr refuses ("already has an attached client") while it's held.
    public let takeover: Bool
    private let endpoint: HerdrEndpoint
    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var pendingStdout = Data()
    private var closed = false

    /// Raw ANSI bytes for the terminal surface. Called on a background queue.
    public var onFrame: (@Sendable (Data) -> Void)?
    /// The pane's size as each frame reports it (columns, rows), before
    /// `onFrame`. Called on the same background queue.
    public var onFrameSize: (@Sendable (Int, Int) -> Void)?
    /// The stream ended; the reason comes from herdr's `terminal.closed`.
    public var onClosed: (@Sendable (String) -> Void)?

    public init(endpoint: HerdrEndpoint, terminalID: String, mode: Mode = .control, takeover: Bool = true) {
        self.endpoint = endpoint
        self.terminalID = terminalID
        self.mode = mode
        self.takeover = takeover
    }

    deinit { close() }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    public func start(columns: Int, rows: Int) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: endpoint.herdrBinary)
        var args = endpoint.sessionArguments + ["terminal", "session"]
        switch mode {
        case .control: args += ["control", terminalID] + (takeover ? ["--takeover"] : [])
        case .observe: args += ["observe", terminalID]
        }
        args += ["--cols", String(max(columns, 2)), "--rows", String(max(rows, 1))]
        process.arguments = args
        process.environment = endpoint.cliEnvironment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        if let log = ProcessInfo.processInfo.environment["BIGTTY_CHANNEL_LOG"],
           FileManager.default.createFile(atPath: log, contents: nil),
           let handle = FileHandle(forWritingAtPath: log)
        {
            process.standardError = handle
        } else {
            process.standardError = FileHandle.nullDevice
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consume(data)
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let alreadyClosed = self.lock.withLock { () -> Bool in
                defer { self.closed = true }
                return self.closed
            }
            if !alreadyClosed { self.onClosed?("exited (\(proc.terminationStatus))") }
        }

        try process.run()
        lock.withLock {
            self.process = process
            self.stdin = input.fileHandleForWriting
        }
    }

    // MARK: - Output

    private struct Record: Decodable {
        let type: String
        let bytes: String?
        let reason: String?
        let width: Int?
        let height: Int?
    }

    private func consume(_ data: Data) {
        pendingStdout.append(data)
        while let nl = pendingStdout.firstIndex(of: 0x0A) {
            let line = pendingStdout[pendingStdout.startIndex..<nl]
            pendingStdout.removeSubrange(pendingStdout.startIndex...nl)
            guard let record = try? JSONDecoder().decode(Record.self, from: line) else { continue }
            switch record.type {
            case "terminal.frame":
                if let width = record.width, let height = record.height { onFrameSize?(width, height) }
                if let b64 = record.bytes, let bytes = Data(base64Encoded: b64) {
                    onFrame?(bytes)
                }
            case "terminal.closed":
                let alreadyClosed = lock.withLock { () -> Bool in
                    defer { closed = true }
                    return closed
                }
                if !alreadyClosed { onClosed?(record.reason ?? "closed") }
            default:
                break
            }
        }
    }

    // MARK: - Input

    private func send(_ message: JSONValue) {
        guard mode == .control, let data = try? JSONEncoder().encode(message) else { return }
        lock.withLock {
            guard !closed, let stdin else { return }
            var line = data
            line.append(0x0A)
            try? stdin.write(contentsOf: line)
        }
    }

    public func sendInput(_ bytes: Data) {
        send(["type": "terminal.input", "bytes": .string(bytes.base64EncodedString())])
    }

    public func resize(columns: Int, rows: Int, cellWidth: Int? = nil, cellHeight: Int? = nil) {
        var message: [String: JSONValue] = [
            "type": "terminal.resize",
            "cols": .number(Double(max(columns, 2))),
            "rows": .number(Double(max(rows, 1))),
        ]
        if let cellWidth, cellWidth > 0 { message["cell_width_px"] = .number(Double(cellWidth)) }
        if let cellHeight, cellHeight > 0 { message["cell_height_px"] = .number(Double(cellHeight)) }
        send(.object(message))
    }

    /// herdr owns scrollback, so wheel scrolling is forwarded to it.
    /// One mouse event at a zero-based cell. herdr encodes it for the
    /// app's mouse mode, and drops it if the app hasn't enabled reporting.
    /// `action`: down, up, drag, move; `button`: left, right, middle;
    /// `modifiers`: Shift 1, Ctrl 2, Alt 4.
    public func mouse(_ action: String, button: String = "left", column: Int, row: Int, modifiers: Int = 0) {
        send([
            "type": "terminal.mouse", "action": .string(action), "button": .string(button),
            "column": .number(Double(max(column, 0))), "row": .number(Double(max(row, 0))),
            "modifiers": .number(Double(modifiers)),
        ])
    }

    public func scroll(up: Bool, lines: Int, column: Int? = nil, row: Int? = nil) {
        var message: [String: JSONValue] = [
            "type": "terminal.scroll",
            "direction": .string(up ? "up" : "down"),
            "lines": .number(Double(max(lines, 1))),
            "source": "wheel",
        ]
        if let column { message["column"] = .number(Double(column)) }
        if let row { message["row"] = .number(Double(row)) }
        send(.object(message))
    }

    /// Gives control back to herdr and ends the stream.
    public func close() {
        send(["type": "terminal.release"])
        let process = lock.withLock { () -> Process? in
            closed = true
            try? stdin?.close()
            stdin = nil
            return self.process
        }
        if let process, process.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
