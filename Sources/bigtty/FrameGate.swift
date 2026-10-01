import Foundation

/// Holds a terminal's frames while it redraws for a new size, so the
/// screen goes straight from the old picture to the settled new one: no
/// flash of the app laid out for the previous size (Claude Code squeezed
/// into another client's width) before it catches up.
///
/// `hold()` starts buffering; the buffer is drawn in one go once frames go
/// quiet for `quiet` seconds, or after `limit` at the latest.
final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.bigtty.frame-gate")
    private let sink: @Sendable (Data) -> Void
    private var holding = false
    private var buffer = Data()
    private var deadline: DispatchTime = .now()
    private var generation = 0
    private let quiet: Double = 0.045
    private let limit: Double = 0.3

    init(sink: @escaping @Sendable (Data) -> Void) {
        self.sink = sink
    }

    /// Buffer frames until the terminal settles.
    func hold() {
        lock.withLock {
            if !holding { deadline = .now() + limit }
            holding = true
        }
        schedule()
    }

    /// Straight through on the caller's thread unless holding: no hop
    /// per frame in the common case.
    func feed(_ data: Data) {
        let held = lock.withLock { () -> Bool in
            guard holding else { return false }
            buffer.append(data)
            return true
        }
        if held { schedule() } else { sink(data) }
    }

    /// Flush after `quiet` without frames, never later than the deadline.
    private func schedule() {
        let (token, at) = lock.withLock { () -> (Int, DispatchTime) in
            generation += 1
            return (generation, min(.now() + quiet, deadline))
        }
        queue.asyncAfter(deadline: at) { [weak self] in self?.flush(token) }
    }

    private func flush(_ token: Int) {
        let frames = lock.withLock { () -> Data? in
            // A later frame (or hold) rescheduled: unless past the
            // deadline, that one flushes.
            guard holding, token == generation || DispatchTime.now() >= deadline else { return nil }
            holding = false
            defer { buffer = Data() }
            return buffer
        }
        // One write: the surface draws the settled screen once.
        if let frames, !frames.isEmpty { sink(frames) }
    }
}

/// True the first time only; safe from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}

/// A grid size shared with a reader thread.
final class LockedSize: @unchecked Sendable {
    private let lock = NSLock()
    private var size: (columns: Int, rows: Int)?

    var value: (columns: Int, rows: Int)? { lock.withLock { size } }
    func set(_ columns: Int, _ rows: Int) { lock.withLock { size = (columns, rows) } }
    func clear() { lock.withLock { size = nil } }
}
