import Foundation

/// Where a files pane's files live: this Mac's disk, or a machine reached
/// over SSH (via its tunnel's shared connection). Every call blocks, so
/// callers run them off the main thread.
final class FileSource: @unchecked Sendable {
    let runner: CommandRunner
    var isRemote: Bool { runner.ssh != nil }

    init(runner: CommandRunner) {
        self.runner = runner
    }

    static let local = FileSource(runner: .local)

    struct Entry: Sendable {
        let name: String
        let isDirectory: Bool
    }

    /// A directory's entries, or nil if it can't be read.
    func list(_ directory: String) -> [Entry]? {
        guard isRemote else {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return nil }
            return names.map { name in
                var dir: ObjCBool = false
                fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name), isDirectory: &dir)
                return Entry(name: name, isDirectory: dir.boolValue)
            }
        }
        // -p marks directories with a trailing slash; -A includes dotfiles.
        guard let out = runner.run("ls", ["-1Ap", "--", directory]) else { return nil }
        return out.split(separator: "\n").map { line in
            line.hasSuffix("/") ? Entry(name: String(line.dropLast()), isDirectory: true) : Entry(name: String(line), isDirectory: false)
        }
    }

    /// Up to `limit` bytes of a file.
    func read(_ path: String, limit: Int) -> Data? {
        guard isRemote else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: limit) ?? Data()
        }
        return runner.runData("head", ["-c", String(limit), "--", path])
    }

    func isDirectory(_ path: String) -> Bool {
        guard isRemote else {
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
        }
        return runner.run("test", ["-d", path]) != nil
    }

    /// Modification time, to notice edits to the open file.
    func modified(_ path: String) -> Double? {
        guard isRemote else {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970
        }
        // GNU stat, then BSD stat.
        let script = "stat -c %Y \"$1\" 2>/dev/null || stat -f %m \"$1\""
        return runner.run("sh", ["-c", script, "sh", path]).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The home directory, for panes with no better starting point.
    func exists(_ path: String) -> Bool {
        guard isRemote else { return FileManager.default.fileExists(atPath: path) }
        return runner.run("test", ["-e", path]) != nil
    }

    func home() -> String {
        guard isRemote else { return NSHomeDirectory() }
        return runner.run("sh", ["-c", "printf %s \"$HOME\""]) ?? "/"
    }
}
