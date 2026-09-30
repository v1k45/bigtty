import Foundation

/// The little git a file pane needs, through the `git` CLI.
struct GitClient: Sendable {
    let root: String

    enum Change: Sendable, Equatable {
        case modified, added, deleted, renamed, untracked, conflicted

        var letter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "U"
            case .conflicted: "!"
            }
        }
    }

    struct Status: Sendable {
        /// Repository top level, absolute.
        let top: String
        /// Absolute path → change.
        let changes: [String: Change]
    }

    /// The repository containing `path`, or nil outside git.
    static func repository(containing path: String) -> GitClient? {
        let dir = isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
        guard let top = run(["rev-parse", "--show-toplevel"], in: dir)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }
        return GitClient(root: top)
    }

    func status() -> Status {
        var changes: [String: Change] = [:]
        guard let out = Self.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root) else {
            return Status(top: root, changes: [:])
        }
        var entries = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            let change: Change
            switch (x, y) {
            case ("?", "?"): change = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): change = .conflicted
            case ("R", _), (_, "R"):
                change = .renamed
                _ = entries.popFirst() // the original path follows a rename
            case ("A", _): change = .added
            case ("D", _), (_, "D"): change = .deleted
            default: change = .modified
            }
            changes[(root as NSString).appendingPathComponent(path)] = change
        }
        return Status(top: root, changes: changes)
    }

    /// Unified diff of `path` against HEAD (staged and unstaged together);
    /// untracked files diff against nothing.
    func diff(_ path: String, untracked: Bool) -> String {
        if untracked {
            return Self.run(["diff", "--no-color", "--no-index", "--", "/dev/null", path], in: root, okStatuses: [0, 1]) ?? ""
        }
        let head = Self.run(["rev-parse", "--verify", "-q", "HEAD"], in: root) != nil
        let args = head ? ["diff", "--no-color", "HEAD", "--", path] : ["diff", "--no-color", "--cached", "--", path]
        return Self.run(args, in: root) ?? ""
    }

    // MARK: -

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    static func run(_ args: [String], in dir: String, okStatuses: Set<Int32> = [0]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard okStatuses.contains(process.terminationStatus) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
