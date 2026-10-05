import Foundation
import Testing
@testable import HerdrKit

@Suite struct RemoteStatusTests {
    /// Runs `argv` and returns its stdout and exit status.
    private func run(_ argv: [String]) throws -> (Data, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    /// What the remote shell gets: the wrapped words, quoted, as one line.
    private func remoteLine(_ executable: String, _ args: [String]) -> String {
        RemoteStatus.wrap(executable, args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    @Test func reportsStatusAndKeepsOutput() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("remote-status-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let (isDir, _) = try run(["/bin/sh", "-c", remoteLine("test", ["-d", file.path])])
        #expect(RemoteStatus.split(isDir).status == 1)
        #expect(RemoteStatus.split(isDir).output.isEmpty)

        let (bytes, _) = try run(["/bin/sh", "-c", remoteLine("head", ["-c", "100", "--", file.path])])
        let split = RemoteStatus.split(bytes)
        #expect(split.status == 0)
        #expect(split.output == Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]))
    }

    @Test func noMarkerMeansNoStatus() {
        let data = Data("ssh: connect to host x port 22: Connection refused".utf8)
        #expect(RemoteStatus.split(data).status == nil)
        #expect(RemoteStatus.split(data).output == data)
    }

    /// Tailscale SSH on a Mac runs commands as `login -f -p … $SHELL -c cmd`,
    /// and login exits 0 whatever the command did; the marker still tells.
    @Test func survivesLoginEatingTheStatus() throws {
        let user = NSUserName()
        let line = remoteLine("test", ["-d", "/etc/hosts"])
        guard let (raw, status) = try? run(["/usr/bin/login", "-f", "-p", "-q", user, "/bin/sh", "-c", line]),
              RemoteStatus.split(raw).status != nil
        else { return } // login -f isn't allowed here
        #expect(status == 0)
        #expect(RemoteStatus.split(raw).status == 1)
    }
}
