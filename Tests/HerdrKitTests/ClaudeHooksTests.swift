import Foundation
@testable import HerdrKit
import Testing

@Suite struct ClaudeHooksTests {
    let command = ClaudeHooks.command(btty: "/Applications/bigtty.app/Contents/MacOS/btty")

    func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func notificationGroups(_ settings: [String: Any]) -> [[String: Any]] {
        ((settings["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]) ?? []
    }

    @Test func commandQuotesThePath() {
        #expect(ClaudeHooks.command(btty: "/a b/it's/btty") == "'/a b/it'\\''s/btty' notify --claude-hook")
    }

    @Test func installsIntoEmptySettings() {
        let (settings, changed) = ClaudeHooks.install([:], command: command)
        #expect(changed)
        let groups = notificationGroups(settings)
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "push_notification")
        #expect(ClaudeHooks.installed(in: settings) == [command])
    }

    @Test func installingTwiceChangesNothing() {
        let once = ClaudeHooks.install([:], command: command).settings
        let twice = ClaudeHooks.install(once, command: command)
        #expect(!twice.changed)
        #expect(ClaudeHooks.installed(in: twice.settings).count == 1)
    }

    @Test func keepsOtherHooksAndSettings() {
        let settings = json("""
        {"model": "opus", "env": {"A": "1"},
         "hooks": {
           "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
           "Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "terminal-notifier -message hi"}]}]
         }}
        """)
        let (installed, changed) = ClaudeHooks.install(settings, command: command)
        #expect(changed)
        #expect(installed["model"] as? String == "opus")
        #expect((installed["env"] as? [String: String]) == ["A": "1"])
        #expect(((installed["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1)
        let groups = notificationGroups(installed)
        #expect(groups.count == 2)
        #expect((groups[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "terminal-notifier -message hi")

        let (removed, removedChanged) = ClaudeHooks.uninstall(installed)
        #expect(removedChanged)
        #expect(NSDictionary(dictionary: removed).isEqual(to: settings))
    }

    @Test func aMovedAppUpdatesTheCommandInPlaceOfAddingOne() {
        let old = ClaudeHooks.install([:], command: ClaudeHooks.command(btty: "/old/btty")).settings
        let (updated, changed) = ClaudeHooks.install(old, command: command)
        #expect(changed)
        #expect(ClaudeHooks.installed(in: updated) == [command])
        #expect(notificationGroups(updated).count == 1)
    }

    @Test func uninstallLeavesAGroupItSharesWithOtherHooks() {
        let settings = json("""
        {"hooks": {"Notification": [{"matcher": "push_notification", "hooks": [
          {"type": "command", "command": "'/x/btty' notify --claude-hook"},
          {"type": "command", "command": "logger hi"}]}]}}
        """)
        let (removed, changed) = ClaudeHooks.uninstall(settings)
        #expect(changed)
        let hooks = notificationGroups(removed).first?["hooks"] as? [[String: Any]]
        #expect(hooks?.map { $0["command"] as? String } == ["logger hi"])
    }

    @Test func uninstallWithoutOurHookChangesNothing() {
        let settings = json(#"{"hooks": {"Notification": [{"hooks": [{"type": "command", "command": "logger"}]}]}}"#)
        #expect(!ClaudeHooks.uninstall(settings).changed)
        #expect(!ClaudeHooks.uninstall([:]).changed)
    }

    @Test func settingsPathFollowsClaudeConfigDir() {
        #expect(ClaudeHooks.settingsURL(environment: ["HOME": "/h"]).path == "/h/.claude/settings.json")
        #expect(ClaudeHooks.settingsURL(environment: ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"]).path == "/c/settings.json")
    }

    @Test func writesJSONThatReadsBackTheSame() throws {
        let text = #"{"b": true, "n": 5, "f": 1.5, "z": null, "s": "a\"b\\c\n\u0001é/✓", "e": {}, "l": [], "o": {"x": [1, false]}}"#
        let settings = json(text)
        let written = ClaudeHooks.json(settings)
        #expect(NSDictionary(dictionary: json(written)).isEqual(to: settings))
        #expect(written.contains(#""b": true"#))
        #expect(written.contains(#""n": 5,"#))
        #expect(written.hasPrefix("{\n  \"b\": true"))
    }

    // MARK: - The file

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createsTheFileWhenThereIsNone() throws {
        let url = try tempDir().appendingPathComponent(".claude/settings.json")
        let outcome = try ClaudeHooks.update(url) { ClaudeHooks.install($0, command: command) }
        #expect(outcome == .written(backup: nil))
        let written = json(try String(contentsOf: url, encoding: .utf8))
        #expect(ClaudeHooks.installed(in: written) == [command])
    }

    @Test func backsUpKeepsPermissionsAndSkipsNoOps() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        let original = #"{"model": "opus"}"#
        try original.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        guard case let .written(backup?) = try ClaudeHooks.update(url, { ClaudeHooks.install($0, command: command) }) else {
            Issue.record("expected a backup")
            return
        }
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        #expect(mode(url.path) == 0o600)
        #expect(mode(backup.path) == 0o600)
        #expect(json(try String(contentsOf: url, encoding: .utf8))["model"] as? String == "opus")

        #expect(try ClaudeHooks.update(url) { ClaudeHooks.install($0, command: command) } == .unchanged)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("bigtty-backup") }
        #expect(backups.count == 1)
    }

    /// The rewritten file has the original's mode before it replaces it,
    /// so there's no moment it sits there with default permissions.
    @Test func newFileHasTheModeBeforeItReplacesTheOld() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        let mode = { (path: String) in (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        var seen: Int?
        try ClaudeHooks.write(Data("new".utf8), to: url, mode: 0o640) { temp in
            seen = mode(temp.path)
            #expect((try? String(contentsOf: temp, encoding: .utf8)) == "new")
        }
        #expect(seen == 0o640)
        #expect(mode(url.path) == 0o640)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test func failedWriteLeavesTheOriginal() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try ClaudeHooks.write(Data("new".utf8), to: url, mode: 0o600) { _ in throw Stop() }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
    }

    @Test func leavesAFileThatIsNotJSONAlone() throws {
        let url = try tempDir().appendingPathComponent("settings.json")
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ClaudeHooks.SettingsError.self) {
            try ClaudeHooks.update(url) { ClaudeHooks.install($0, command: command) }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }

    @Test func writesThroughASymlink() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try ClaudeHooks.update(link) { ClaudeHooks.install($0, command: command) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(ClaudeHooks.installed(in: json(try String(contentsOf: real, encoding: .utf8))) == [command])
    }
}
