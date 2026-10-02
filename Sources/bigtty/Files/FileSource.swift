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
        return check("-d", path)
    }

    /// `test` over SSH, read from what it prints rather than its exit
    /// status: a server that reports every command as successful (seen
    /// through Tailscale SSH) would otherwise make every path a folder.
    private func check(_ flag: String, _ path: String) -> Bool {
        runner.run("sh", ["-c", "test \(flag) \"$1\" && echo yes", "sh", path])?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
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
        return check("-e", path)
    }

    /// Why a file came back empty or unusable, in words for the pane:
    /// its size where it lives, and for SSH the error and login user.
    func diagnose(_ path: String) -> String {
        guard let ssh = runner.ssh else {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
            return size.map { "It is \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) on this Mac." }
                ?? "This Mac can't open it."
        }
        let script = "printf 'user %s\\n' \"$(id -un)\"; ls -ln -- \"$1\" 2>&1; head -c 16 -- \"$1\" | od -An -tx1 | head -1"
        let command = ["sh", "-c", script, "sh", path].map(SSHTunnel.shellQuote).joined(separator: " ")
        guard let result = SSHTunnel.runSSH(ssh, remoteCommand: command) else { return "ssh didn't run." }
        let error = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["Over SSH (\(ssh.target), exit \(result.status)):", output, error.isEmpty ? nil : "ssh: " + error]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func home() -> String {
        guard isRemote else { return NSHomeDirectory() }
        return runner.run("sh", ["-c", "printf %s \"$HOME\""]) ?? "/"
    }
}
