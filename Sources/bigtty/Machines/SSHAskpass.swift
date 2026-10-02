import AppKit
import HerdrKit
import Security

/// Answers what `ssh` asks while connecting to a machine: a password, a
/// key's passphrase, a one-time code, or whether to trust a new host key.
///
/// Every `ssh` bigtty starts sets `SSH_ASKPASS` to `btty`, which forwards
/// the question here (`ssh.askpass` on the control socket). A machine uses
/// several connections (commands, the herdr tunnel, browser forwards), each
/// asking the same thing, so an answer is kept in memory for the machine and
/// given to the next connection without asking again; passwords and
/// passphrases can also be kept in the Keychain. A cancel, or an answer ssh
/// asks for again (it was wrong), stops the asking for that machine until
/// you connect it yourself, so background reconnects never pile up dialogs.
@MainActor
final class SSHAskpass {
    static let shared = SSHAskpass()

    private enum Kind {
        /// A password or passphrase: hidden, may go in the Keychain.
        case secret
        /// A one-time code or other question: shown, never stored.
        case code
        /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        case confirm
    }

    private var answers: [String: String] = [:]
    /// The ssh process each answer was last given to: the same one asking
    /// again means the answer was wrong.
    private var answeredBy: [String: Int] = [:]
    private var declined: Set<String> = []
    private var asking: [String: Task<String?, Never>] = [:]

    /// The environment for an `ssh` connecting to `target`.
    nonisolated static func environment(target: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("btty").path
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["BIGTTY_ASKPASS"] = "1"
        env["BIGTTY_ASKPASS_TARGET"] = target
        env["BIGTTY_SOCKET"] = BigttyControl.socketPath
        return env
    }

    /// You chose to connect: ask again even after a cancel.
    func allow(_ target: String) {
        declined.remove(target)
    }

    func answer(prompt: String, target: String, sshPID: Int) async -> String? {
        guard !declined.contains(target) else { return nil }
        let kind = Self.kind(of: prompt)
        let key = target + "\n" + prompt
        // The same ssh asking again means the answer it got was wrong.
        let retry = answeredBy[key] == sshPID && kind != .confirm
        if retry {
            answers[key] = nil
            Task.detached { Keychain.delete(key) }
        }
        if let known = answers[key] {
            answeredBy[key] = sshPID
            return known
        }
        // Several connections may ask at once: one lookup and one dialog for
        // all of them, joined before anything waits (a connection that
        // waited on the Keychain first would miss the dialog in progress).
        if let pending = asking[key] { return await pending.value }
        let task = Task { @MainActor () -> String? in
            // Off the main thread: the Keychain may be slow, or ask to unlock.
            if kind == .secret, !retry, let stored = await Task.detached(operation: { Keychain.read(key) }).value {
                return stored
            }
            return self.ask(prompt: prompt, target: target, kind: kind, key: key, retry: retry)
        }
        asking[key] = task
        let result = await task.value
        asking[key] = nil
        if let result {
            answers[key] = result
            answeredBy[key] = sshPID
        } else {
            declined.insert(target)
        }
        return result
    }

    private static func kind(of prompt: String) -> Kind {
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") || lower.contains("continue connecting") { return .confirm }
        if lower.contains("password") || lower.contains("passphrase") { return .secret }
        return .code
    }

    private func ask(prompt: String, target: String, kind: Kind, key: String, retry: Bool) -> String? {
        // Debug: BIGTTY_DEBUG_ASKPASS answers instead of a dialog ("-"
        // cancels); BIGTTY_DEBUG_ASKPASS_LOG gets a line per dialog.
        let env = ProcessInfo.processInfo.environment
        if let log = env["BIGTTY_DEBUG_ASKPASS_LOG"], let handle = FileHandle(forWritingAtPath: log) ?? {
            FileManager.default.createFile(atPath: log, contents: nil)
            return FileHandle(forWritingAtPath: log)
        }() {
            handle.seekToEndOfFile()
            handle.write(Data("\(kind) retry=\(retry) \(target): \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\n".utf8))
            try? handle.close()
        }
        if let answer = env["BIGTTY_DEBUG_ASKPASS"] { return answer == "-" ? nil : (kind == .confirm ? "yes" : answer) }
        NSApp.activate()
        let alert = NSAlert()
        let text = (retry ? "That didn’t work. " : "") + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .confirm:
            alert.messageText = "Trust \(target)?"
            alert.informativeText = text
            alert.addButton(withTitle: "Trust and Connect")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? "yes" : nil
        case .secret, .code:
            alert.messageText = "Sign in to \(target)"
            alert.informativeText = text
            let field: NSTextField = kind == .secret ? NSSecureTextField() : NSTextField()
            field.frame = NSRect(x: 0, y: 26, width: 280, height: 24)
            let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
            remember.frame = NSRect(x: 0, y: 0, width: 280, height: 18)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: kind == .secret ? 50 : 24))
            if kind == .secret {
                box.addSubview(field)
                box.addSubview(remember)
            } else {
                field.frame.origin.y = 0
                box.addSubview(field)
            }
            alert.accessoryView = box
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            // The field takes the typing straight away (an alert only
            // honours this once laid out).
            alert.layout()
            alert.window.initialFirstResponder = field
            alert.window.makeFirstResponder(field)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = field.stringValue
            if kind == .secret, remember.state == .on { Task.detached { Keychain.save(value, for: key) } }
            return value
        }
    }
}

/// Passwords and passphrases kept for SSH logins, by "target\nprompt".
private enum Keychain {
    private static let service = "bigtty SSH"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: "bigtty SSH login",
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
