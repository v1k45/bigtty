import Foundation

/// A remote command's own exit status, carried in its output. ssh normally
/// exits with the command's status, but Tailscale SSH on a Mac runs
/// commands through `/usr/bin/login`, which always exits 0: a failed
/// `test -d` there reads as success. So the command runs inside a small
/// `sh` that appends a marker and the real status after its output.
public enum RemoteStatus {
    static let marker = Data("\u{1}bigtty-exit:".utf8)

    /// `executable args…` wrapped to report its status; quote each word
    /// for the remote shell.
    public static func wrap(_ executable: String, _ args: [String]) -> [String] {
        ["sh", "-c", "\"$@\"; s=$?; printf '\\001bigtty-exit:%d' \"$s\"; exit \"$s\"", "sh", executable] + args
    }

    /// The command's output and status, or the output unchanged and nil
    /// when there's no marker (the shell never ran).
    public static func split(_ data: Data) -> (output: Data, status: Int32?) {
        guard let range = data.range(of: marker, options: .backwards),
              let status = Int32(String(decoding: data[range.upperBound...], as: UTF8.self))
        else { return (data, nil) }
        return (Data(data[..<range.lowerBound]), status)
    }
}
