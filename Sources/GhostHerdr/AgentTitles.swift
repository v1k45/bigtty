import Foundation

/// What an agent's conversation is called, from the agent's own session
/// files, for tab names. herdr reports each pane's agent and session id;
/// a small reader per agent knows where that agent keeps its sessions:
///
/// - claude: ~/.claude/projects/<dir>/<id>.jsonl, its latest
///   `agent-name`/`custom-title` (what it puts in the terminal title, or a
///   /rename), else its latest `ai-title` summary
/// - codex: ~/.codex/sessions/…/rollout-…-<id>.jsonl, the first message
///
/// Agents without a reader are named by the generic sources instead (a
/// title reported to herdr, the terminal title).
enum AgentTitles {
    struct Reader: Sendable {
        /// Session files to search, as shell globs relative to $HOME.
        let globs: [String]
        /// Whether a line may carry the title (a cheap filter before JSON).
        let marker: String
        /// Where to look: the file's tail (titles rewritten as it goes on)
        /// or its head (the first message).
        let fromEnd: Bool
        let title: @Sendable ([String]) -> String?
    }

    static let readers: [String: Reader] = [
        "claude": Reader(
            globs: ["${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/*/$ID.jsonl"],
            marker: "\"type\":\"(agent-name|custom-title|ai-title)\"",
            fromEnd: true,
            title: { lines in
                var summary: String?
                for line in lines.reversed() {
                    guard let object = json(line) else { continue }
                    if let name = (object["agentName"] ?? object["customTitle"]) as? String, !name.isEmpty { return name }
                    if summary == nil, let title = object["aiTitle"] as? String, !title.isEmpty { summary = title }
                }
                return summary
            }
        ),
        "codex": Reader(
            globs: ["${CODEX_HOME:-$HOME/.codex}/sessions/*/*/*/rollout-*-$ID.jsonl"],
            marker: "\"user_message\"",
            fromEnd: false,
            title: { lines in
                for line in lines {
                    guard let payload = json(line)?["payload"] as? [String: Any], payload["type"] as? String == "user_message",
                          let message = payload["message"] as? String else { continue }
                    let first = message.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !first.isEmpty { return String(first.prefix(60)) }
                }
                return nil
            }
        ),
    ]

    private static func json(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
    }

    // MARK: - This Mac

    private struct Cached {
        let path: String
        let modified: Date
        let title: String?
    }

    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    /// Reads only when the file changed since last time.
    static func local(agent: String, sessionID: String) -> String? {
        guard let reader = readers[agent], validID(sessionID) else { return nil }
        let key = agent + "|" + sessionID
        let known = lock.withLock { cache[key] }
        let fm = FileManager.default
        var path = known?.path
        if path == nil || !fm.fileExists(atPath: path!) { path = find(reader, sessionID) }
        guard let path, let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        if let known, known.path == path, known.modified == modified { return known.title }
        let title = read(path, reader: reader)
        lock.withLock { cache[key] = Cached(path: path, modified: modified, title: title) }
        return title
    }

    /// Expands the reader's globs (only `*` path components) for this id.
    private static func find(_ reader: Reader, _ id: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        for glob in reader.globs {
            var pattern = glob.replacingOccurrences(of: "$ID", with: id)
            for (name, fallback) in [("CLAUDE_CONFIG_DIR", "/.claude"), ("CODEX_HOME", "/.codex")] {
                pattern = pattern.replacingOccurrences(of: "${\(name):-$HOME\(fallback)}", with: env[name].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + fallback)
            }
            var candidates = [""]
            for part in pattern.split(separator: "/").map(String.init) {
                var next: [String] = []
                for base in candidates {
                    if part.contains("*") {
                        let entries = (try? fm.contentsOfDirectory(atPath: base.isEmpty ? "/" : base)) ?? []
                        let regex = "^" + NSRegularExpression.escapedPattern(for: part).replacingOccurrences(of: "\\*", with: ".*") + "$"
                        next += entries.filter { $0.range(of: regex, options: .regularExpression) != nil }.map { base + "/" + $0 }
                    } else {
                        next.append(base + "/" + part)
                    }
                }
                candidates = next
            }
            if let hit = candidates.sorted().last(where: { fm.fileExists(atPath: $0) }) { return hit }
        }
        return nil
    }

    private static func read(_ path: String, reader: Reader) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let window: UInt64 = 512 * 1024
        if reader.fromEnd {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > window ? size - window : 0)
        }
        guard let data = reader.fromEnd ? try? handle.readToEnd() : try? handle.read(upToCount: Int(window)) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.range(of: reader.marker, options: .regularExpression) != nil }
        return reader.title(lines)
    }

    // MARK: - Another machine

    /// A shell snippet printing "T<tab>agent<tab>id<tab>line" for the
    /// candidate lines of each session's file.
    static func remoteScript(sessions: [(agent: String, id: String)]) -> String {
        sessions.compactMap { session -> String? in
            guard let reader = readers[session.agent], validID(session.id) else { return nil }
            let globs = reader.globs.map { $0.replacingOccurrences(of: "$ID", with: session.id) }.joined(separator: " ")
            let source = reader.fromEnd ? "tail -c 524288 \"$f\"" : "head -c 524288 \"$f\""
            return """
            f=$(ls \(globs) 2>/dev/null | tail -1); [ -n "$f" ] && \(source) | grep -E '\(reader.marker)' | \(reader.fromEnd ? "tail" : "head") -n 40 | while IFS= read -r l; do printf 'T\\t%s\\t%s\\t%s\\n' '\(session.agent)' '\(session.id)' "$l"; done
            """
        }.joined(separator: "\n")
    }

    /// Titles from `remoteScript`'s output lines ("agent<tab>id<tab>line").
    static func parseRemote(_ lines: [Substring]) -> [String: String] {
        var grouped: [String: (agent: String, lines: [String])] = [:]
        for line in lines {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            grouped[parts[1], default: (parts[0], [])].lines.append(parts[2])
        }
        return grouped.compactMapValues { readers[$0.agent]?.title($0.lines) }
    }
}
