import Foundation
import HerdrKit

/// What every terminal pane shows (and recently showed), for ⌘K to search:
/// read over herdr's API in parallel when the palette opens, cached, and
/// searched as bytes, so a keystroke costs a millisecond or two.
@MainActor
final class TerminalIndex {
    static let shared = TerminalIndex()

    struct Hit {
        let machineID: String
        let pane: Pane
        /// The matching line, trimmed to a window around the match.
        let snippet: String
        /// The match within `snippet` (UTF-16).
        let match: NSRange
        /// Lines from the bottom of the pane: 0 is the newest.
        let age: Int
    }

    private struct Entry {
        let terminalID: String
        let fetched: Date
        /// Lowercased UTF-8 of the whole text, searched with memmem.
        let lower: [UInt8]
        let text: [UInt8]
    }

    private var entries: [String: Entry] = [:]
    private var refreshing = false
    /// Called when fresh text arrives, so an open palette can re-search.
    var onUpdate: (() -> Void)?

    /// Re-reads panes whose text is older than a few seconds.
    func refresh(_ machines: [Machine]) {
        guard !refreshing else { return }
        var jobs: [(key: String, pane: Pane, client: HerdrClient)] = []
        var live = Set<String>()
        for machine in machines {
            guard let store = machine.store, case .connected = store.state else { continue }
            for pane in store.snapshot.panes where pane.hostKind == nil {
                let key = machine.id + "|" + pane.paneID
                live.insert(key)
                if let entry = entries[key], entry.terminalID == pane.terminalID, Date().timeIntervalSince(entry.fetched) < 4 { continue }
                jobs.append((key, pane, store.client))
            }
        }
        entries = entries.filter { live.contains($0.key) }
        guard !jobs.isEmpty else { return }
        refreshing = true
        Task {
            let results = await withTaskGroup(of: (String, String, String?).self) { group in
                for job in jobs {
                    group.addTask {
                        let text = try? await job.client.readPane(job.pane.paneID)
                        return (job.key, job.pane.terminalID, text)
                    }
                }
                var all: [(String, String, String?)] = []
                for await result in group { all.append(result) }
                return all
            }
            let now = Date()
            for (key, terminalID, text) in results {
                guard let text else { continue }
                let bytes = Array(text.utf8)
                entries[key] = Entry(terminalID: terminalID, fetched: now, lower: Self.lowercasedASCII(bytes), text: bytes)
            }
            refreshing = false
            onUpdate?()
        }
    }

    /// Lines containing `query` (case-insensitive), newest first, at most
    /// `perPane` per pane.
    func search(_ query: String, in machines: [Machine], limit: Int = 8, perPane: Int = 2) -> [Hit] {
        let needle = Self.lowercasedASCII(Array(query.utf8))
        guard needle.count >= 2 else { return [] }
        var hits: [Hit] = []
        for machine in machines {
            guard let store = machine.store else { continue }
            for pane in store.snapshot.panes where pane.hostKind == nil {
                guard let entry = entries[machine.id + "|" + pane.paneID] else { continue }
                hits += find(needle, in: entry, limit: perPane).map {
                    Hit(machineID: machine.id, pane: pane, snippet: $0.snippet, match: $0.match, age: $0.age)
                }
            }
        }
        return Array(hits.sorted { $0.age < $1.age }.prefix(limit))
    }

    /// Matches from the end of the text backwards, one per line.
    private func find(_ needle: [UInt8], in entry: Entry, limit: Int) -> [(snippet: String, match: NSRange, age: Int)] {
        var found: [(String, NSRange, Int)] = []
        var starts: [Int] = []
        entry.lower.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                guard let base = hay.baseAddress, let p = pin.baseAddress else { return }
                var offset = 0
                while offset < hay.count, let hit = memmem(base + offset, hay.count - offset, p, pin.count) {
                    let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    starts.append(at)
                    offset = at + pin.count
                }
            }
        }
        var seenLines = Set<Int>()
        for at in starts.reversed() {
            // The line around the match.
            var lineStart = at
            while lineStart > 0, entry.text[lineStart - 1] != 10 { lineStart -= 1 }
            guard seenLines.insert(lineStart).inserted else { continue }
            var lineEnd = at
            while lineEnd < entry.text.count, entry.text[lineEnd] != 10 { lineEnd += 1 }
            let age = entry.text[lineEnd...].reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            // A window of the line around the match, whole characters.
            let windowStart = max(lineStart, at - 40)
            let windowEnd = min(lineEnd, at + needle.count + 70)
            guard let snippet = Self.decode(entry.text[windowStart..<windowEnd]) else { continue }
            let before = Self.decode(entry.text[windowStart..<at]) ?? ""
            let matchText = Self.decode(entry.text[at..<(at + needle.count)]) ?? ""
            let lead = windowStart > lineStart ? "…" : ""
            let trimmed = lead + snippet.trimmingCharacters(in: .whitespaces)
            let leadingSpaces = snippet.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let location = lead.utf16.count + before.utf16.count - leadingSpaces
            guard location >= 0 else { continue }
            found.append((trimmed + (windowEnd < lineEnd ? "…" : ""), NSRange(location: location, length: matchText.utf16.count), age))
            if found.count >= limit { break }
        }
        return found
    }

    /// Lossy for a cut multi-byte character at the edges: drops it.
    private static func decode(_ bytes: ArraySlice<UInt8>) -> String? {
        var slice = bytes
        while let first = slice.first, first & 0xC0 == 0x80 { slice = slice.dropFirst() }
        while let last = slice.last, last & 0x80 != 0 {
            // Stop at a complete sequence's last byte.
            if String(bytes: slice, encoding: .utf8) != nil { break }
            slice = slice.dropLast()
        }
        return String(bytes: slice, encoding: .utf8)
    }

    private static func lowercasedASCII(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    }
}
