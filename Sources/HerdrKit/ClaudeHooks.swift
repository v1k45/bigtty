import Foundation

/// The Claude Code hook that sends Claude's notifications (its
/// PushNotification tool) to bigtty: `btty hooks install claude`.
///
/// Claude Code writes a terminal notification only for terminals it knows,
/// and herdr redraws panes rather than passing escapes through, so they
/// never reach bigtty. Its `Notification` hook runs either way; this one
/// calls `btty notify --claude-hook`, which puts the message on Needs You.
///
/// Edits to settings.json are merges: other hooks and settings stay as
/// they are, and only entries running `btty notify --claude-hook` count
/// as ours.
public enum ClaudeHooks {
    public static let event = "Notification"
    /// Only what Claude sends on purpose. Permission prompts and idle turns
    /// already reach Needs You through herdr's agent state.
    public static let matcher = "push_notification"
    static let marker = "notify --claude-hook"

    /// The hook's command, running the `btty` at `path`.
    public static func command(btty path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))' \(marker)"
    }

    public static func isOurs(_ command: String) -> Bool { command.contains(marker) }

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func settingsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
    }

    // MARK: - Merging

    /// Our hook commands in `settings`.
    public static func installed(in settings: [String: Any]) -> [String] {
        groups(settings).flatMap { hooks(in: $0) }.compactMap { $0["command"] as? String }.filter(isOurs)
    }

    /// `settings` with our hook, running `command`, and whether that changed anything.
    public static func install(_ settings: [String: Any], command: String) -> (settings: [String: Any], changed: Bool) {
        let ours = groups(settings).filter { hooks(in: $0).contains { ($0["command"] as? String).map(isOurs) ?? false } }
        if ours.count == 1, let group = ours.first, group["matcher"] as? String == matcher,
           hooks(in: group).count == 1, hooks(in: group).first?["command"] as? String == command
        {
            return (settings, false)
        }
        var result = uninstall(settings).settings
        var hooksObject = result["hooks"] as? [String: Any] ?? [:]
        var list = hooksObject[event] as? [Any] ?? []
        list.append([
            "matcher": matcher,
            "hooks": [["type": "command", "command": command, "timeout": 10] as [String: Any]],
        ] as [String: Any])
        hooksObject[event] = list
        result["hooks"] = hooksObject
        return (result, true)
    }

    /// `settings` without our hook, and whether it had one. Groups and
    /// lists left empty by that go too; everything else stays.
    public static func uninstall(_ settings: [String: Any]) -> (settings: [String: Any], changed: Bool) {
        guard var hooksObject = settings["hooks"] as? [String: Any], let list = hooksObject[event] as? [Any] else {
            return (settings, false)
        }
        var changed = false
        var kept: [Any] = []
        for item in list {
            guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else {
                kept.append(item)
                continue
            }
            let remaining = entries.filter { entry in
                guard let command = (entry as? [String: Any])?["command"] as? String else { return true }
                return !isOurs(command)
            }
            if remaining.count == entries.count {
                kept.append(item)
                continue
            }
            changed = true
            if remaining.isEmpty { continue }
            group["hooks"] = remaining
            kept.append(group)
        }
        guard changed else { return (settings, false) }
        var result = settings
        if kept.isEmpty { hooksObject[event] = nil } else { hooksObject[event] = kept }
        result["hooks"] = hooksObject.isEmpty ? nil : hooksObject
        return (result, true)
    }

    private static func groups(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func hooks(in group: [String: Any]) -> [[String: Any]] {
        (group["hooks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    // MARK: - The file

    public struct SettingsError: Error, CustomStringConvertible {
        public let description: String
    }

    public enum Outcome: Equatable {
        case unchanged
        /// Written; the file as it was is at `backup` (nil: there was none).
        case written(backup: URL?)
    }

    /// Reads `url`'s settings (none yet: empty), applies `change`, and writes
    /// the result if it differs, after copying the file aside. A file that
    /// isn't a JSON object is left alone. A symlinked file (dotfiles) is
    /// written through the link; its permissions are kept.
    public static func update(
        _ url: URL, now: Date = Date(),
        _ change: ([String: Any]) -> (settings: [String: Any], changed: Bool)
    ) throws -> Outcome {
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let original = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        var settings: [String: Any] = [:]
        if let original, !original.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            guard let object = try? JSONSerialization.jsonObject(with: original), let dict = object as? [String: Any] else {
                throw SettingsError(description: "\(url.path) isn't a JSON object; left it unchanged")
            }
            settings = dict
        }
        let (updated, changed) = change(settings)
        guard changed else { return .unchanged }

        var backup: URL?
        if let original {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            var candidate = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).bigtty-backup-\(stamp.string(from: now))")
            var n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = target.deletingLastPathComponent()
                    .appendingPathComponent("\(target.lastPathComponent).bigtty-backup-\(stamp.string(from: now))-\(n)")
                n += 1
            }
            // A copy keeps the file's permissions (it may hold tokens).
            try fm.copyItem(at: target, to: candidate)
            backup = candidate
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try Data((json(updated) + "\n").utf8).write(to: target, options: .atomic)
        if let permissions {
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return .written(backup: backup)
    }

    /// JSON as Claude Code writes it (two-space indent, `"key": value`),
    /// keys sorted (JSONSerialization keeps no order).
    static func json(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let dict as [String: Any]:
            guard !dict.isEmpty else { return "{}" }
            let members = dict.keys.sorted().map { "\(inner)\(json($0)): \(json(dict[$0]!, indent: inner))" }
            return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + json($0, indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case let string as String:
            var out = "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out + "\""
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return String(data: (try? JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed)) ?? Data("0".utf8),
                          encoding: .utf8) ?? "0"
        default:
            return "null"
        }
    }
}
