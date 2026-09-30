import Foundation

/// Holds a terminal's frames while it redraws for a new size, so the
/// screen goes straight from the old picture to the settled new one: no
/// flash of the app laid out for the previous size (Claude Code squeezed
/// into another client's width) before it catches up.
///
/// `hold()` starts buffering; the buffer is drawn in one go once frames go
/// quiet for `quiet` seconds, or after `limit` at the latest.
final class FrameGate: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.ghostherdr.frame-gate")
    private let sink: @Sendable (Data) -> Void
    private var holding = false
    private var buffer: [Data] = []
    private var deadline: DispatchTime = .now()
    private var flushWork: DispatchWorkItem?
    private let quiet: Double = 0.045
    private let limit: Double = 0.3

    init(sink: @escaping @Sendable (Data) -> Void) {
        self.sink = sink
    }

    /// Buffer frames until the terminal settles.
    func hold() {
        queue.async { [self] in
            if !holding { deadline = .now() + limit }
            holding = true
            schedule()
        }
    }

    func feed(_ data: Data) {
        queue.async { [self] in
            guard holding else { return sink(data) }
            buffer.append(data)
            schedule()
        }
    }

    /// Flush after `quiet` without frames, never later than the deadline.
    private func schedule() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        let quietAt = DispatchTime.now() + quiet
        queue.asyncAfter(deadline: min(quietAt, deadline), execute: work)
    }

    private func flush() {
        holding = false
        flushWork = nil
        let frames = buffer
        buffer = []
        // One write: the surface draws the settled screen once.
        if !frames.isEmpty { sink(frames.reduce(into: Data()) { $0.append($1) }) }
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
