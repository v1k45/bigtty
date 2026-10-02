import Foundation

/// The little git a file pane needs, through the `git` CLI, on this Mac or
/// on a machine over SSH.
struct GitClient: Sendable {
    let root: String
    var runner: CommandRunner = .local

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
    static func repository(containing path: String, runner: CommandRunner = .local) -> GitClient? {
        let source = FileSource(runner: runner)
        let dir = source.isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
        guard let top = runner.run("git", ["-C", dir, "rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }
        return GitClient(root: top, runner: runner)
    }

    private func git(_ args: [String], okStatuses: Set<Int32> = [0]) -> String? {
        runner.run("git", ["-C", root] + args, okStatuses: okStatuses)
    }

    /// Repository files (tracked and untracked, not ignored) whose name is
    /// `name`, or whose path ends in `name` ("screenshots/workspace.png").
    func files(named name: String) -> [String] {
        // git matches the name itself (pathspecs), so ignored folders are
        // skipped and only hits come back.
        guard let out = git(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", name, ":(glob)**/\(name)"])
        else { return [] }
        return out.split(separator: "\0").map(String.init)
            .map { (root as NSString).appendingPathComponent($0) }
    }

    /// Where else in the repo a clicked path is: the repo's other worktrees
    /// (an agent may work in one while its terminal sits in another). The
    /// path as written is checked in every worktree (a file test each);
    /// a name is looked up in at most the 8 most recently active ones, and
    /// the first that has it wins. One shell call, so one round trip on a
    /// remote machine, however many worktrees there are.
    func findInOtherWorktrees(_ target: String) -> (root: String, paths: [String])? {
        let script = #"""
        here=$1; t=$2
        common=$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
        [ -d "$common/worktrees" ] || exit 0
        # Every worktree with its index's age, newest first, in a fixed few
        # processes however many there are.
        if stat -c %Y / >/dev/null 2>&1; then ages() { stat -c '%Y %n' "$@" 2>/dev/null; }
        else ages() { stat -f '%m %N' "$@" 2>/dev/null; }; fi
        wts=$( {
          awk 'FNR==1 { d = FILENAME; sub(/\/gitdir$/, "", d); w = $0; sub(/\/\.git\/?$/, "", w); print "W\t" d "\t" w }' "$common"/worktrees/*/gitdir 2>/dev/null
          if [ "${common%/.git}" != "$common" ]; then printf 'W\t%s\t%s\n' "$common" "${common%/.git}"; fi
          ages "$common"/worktrees/*/index "$common/index" | awk '{ m = $1; p = substr($0, length($1) + 2); sub(/\/index$/, "", p); print "M\t" p "\t" m }'
        } | awk -F '\t' '$1 == "W" { w[$2] = $3 } $1 == "M" { m[$2] = $3 } END { for (d in w) print (m[d] + 0) "\t" w[d] }' \
          | sort -rn | cut -f2- | grep -vxF "$here")
        # The path as written: a test per worktree, no processes.
        hit=$(printf '%s\n' "$wts" | while IFS= read -r wt; do
          if [ -n "$wt" ] && [ -e "$wt/$t" ]; then printf '%s\t%s/%s\n' "$wt" "$wt" "$t"; break; fi
        done)
        if [ -n "$hit" ]; then printf '%s\n' "$hit"; exit 0; fi
        # A name: asked of the 8 most recently active worktrees.
        printf '%s\n' "$wts" | head -n 8 | while IFS= read -r wt; do
          [ -n "$wt" ] || continue
          m=$(git -C "$wt" ls-files --cached --others --exclude-standard -- "$t" ":(glob)**/$t" 2>/dev/null)
          if [ -n "$m" ]; then
            printf '%s\n' "$m" | while IFS= read -r f; do printf '%s\t%s/%s\n' "$wt" "$wt" "$f"; done
            break
          fi
        done
        """#
        guard let out = runner.run("/bin/sh", ["-c", script, "sh", root, target]) else { return nil }
        let rows = out.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
        guard let first = rows.first else { return nil }
        return (first[0], rows.filter { $0[0] == first[0] }.map { $0[1].hasSuffix("/") && $0[1].count > 1 ? String($0[1].dropLast()) : $0[1] })
    }

    func status() -> Status {
        var changes: [String: Change] = [:]
        guard let out = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]) else {
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
            return git(["diff", "--no-color", "--no-index", "--", "/dev/null", path], okStatuses: [0, 1]) ?? ""
        }
        let head = git(["rev-parse", "--verify", "-q", "HEAD"]) != nil
        let args = head ? ["diff", "--no-color", "HEAD", "--", path] : ["diff", "--no-color", "--cached", "--", path]
        return git(args) ?? ""
    }

    // MARK: -

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }
}
