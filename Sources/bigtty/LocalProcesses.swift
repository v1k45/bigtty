import Darwin
import Foundation

/// The process tree and listening TCP ports on this Mac, straight from the
/// kernel: no `ps` or `lsof` (lsof alone costs a few hundred ms of CPU).
enum LocalProcesses {
    /// pid → parent pid for every process, from one sysctl.
    static func parentMap() -> [Int32: Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Room for processes started in between.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [:] }
        var map: [Int32: Int32] = [:]
        for proc in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            map[proc.kp_proc.p_pid] = proc.kp_eproc.e_ppid
        }
        return map
    }

    /// Listening TCP ports of the given processes.
    static func listeningPorts(of pids: Set<Int32>) -> [Int32: Set<Int>] {
        var result: [Int32: Set<Int>] = [:]
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == SOCKINFO_TCP,
                      info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
                if port > 0 { result[pid, default: []].insert(port) }
            }
        }
        return result
    }

    /// Every process under any of `roots` (roots included).
    static func descendants(of roots: Set<Int32>, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }
        var result = roots
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where result.insert(child).inserted { queue.append(child) }
        }
        return result
    }

    /// The branch checked out in the repository containing `dir`, read from
    /// its HEAD file (worktrees included); "detached" for a bare commit.
    static func gitBranch(_ dir: String) -> String? {
        var url = URL(fileURLWithPath: dir)
        let fm = FileManager.default
        for _ in 0..<40 {
            let dotGit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // A worktree or submodule: "gitdir: <path>".
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                    let path = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst(16)) }
                return trimmed.isEmpty ? nil : "detached"
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}
