import AppKit

/// "Connect a machine": an SSH target, a name and an optional herdr session,
/// with a live check before connecting.
@MainActor
final class ConnectMachineSheet: NSObject, NSTextFieldDelegate {
    private static var current: ConnectMachineSheet?

    static func present(on window: NSWindow, manager: MachineManager, onConnect: @escaping (Machine) -> Void) {
        let sheet = ConnectMachineSheet(manager: manager, onConnect: onConnect)
        current = sheet
        window.beginSheet(sheet.panel) { _ in current = nil }
    }

    private let manager: MachineManager
    private let onConnect: (Machine) -> Void
    private let panel: NSPanel
    private let target = NSTextField()
    private let name = NSTextField()
    private let session = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private var checkTask: Task<Void, Never>?
    private var nameEdited = false

    private init(manager: MachineManager, onConnect: @escaping (Machine) -> Void) {
        self.manager = manager
        self.onConnect = onConnect
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        build()
    }

    private func build() {
        let title = NSTextField(labelWithString: "Connect a machine")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "GhostHerdr connects over SSH with your keys and agent, and shows the spaces of the herdr running there.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 420

        target.placeholderString = "user@host, or an ~/.ssh/config alias"
        target.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        target.delegate = self
        name.placeholderString = "Name in the sidebar"
        name.delegate = self
        session.placeholderString = "default"
        session.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        session.delegate = self
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 390
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        connect.bezelStyle = .rounded
        connect.keyEquivalent = "\r"
        connect.target = self
        connect.action = #selector(connectClicked)
        connect.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        func row(_ label: String, _ field: NSTextField) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.font = .systemFont(ofSize: 12)
            l.textColor = .secondaryLabelColor
            let v = NSStackView(views: [l, field])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 4
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
            return v
        }
        let statusRow = NSStackView(views: [spinner, statusIcon, status])
        statusRow.spacing = 6
        statusRow.alignment = .centerY
        let buttons = NSStackView(views: [cancel, connect])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, intro, row("SSH target", target), row("Name", name), row("herdr session", session), statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: statusRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
        ])
        panel.contentView = content
        panel.initialFirstResponder = target
    }

    // MARK: - Checking

    func controlTextDidChange(_ note: Notification) {
        if (note.object as? NSTextField) === name { nameEdited = true }
        if (note.object as? NSTextField) === target, !nameEdited {
            name.stringValue = target.stringValue.isEmpty ? "" : MachineManager.defaultName(for: target.stringValue)
        }
        if (note.object as? NSTextField) !== name { scheduleCheck() }
    }

    /// Probes the target a moment after typing stops.
    private func scheduleCheck() {
        checkTask?.cancel()
        connect.isEnabled = false
        let value = target.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            show(nil, "")
            return
        }
        guard SSHTunnel.Config.isValid(target: value) else {
            show(false, "That isn’t an SSH target: it can’t start with “-” or contain spaces.")
            return
        }
        let sessionName = session.stringValue.trimmingCharacters(in: .whitespaces)
        show(nil, "Checking \(value)…", spinning: true)
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghostherdr-probe-\(abs(value.hashValue) % 100_000)").path
            let tunnel = SSHTunnel(config: .init(target: value, session: sessionName.isEmpty ? nil : sessionName, directory: dir))
            let start = Date()
            // Tailscale SSH (check mode) may ask to approve the login in the
            // browser first: the person is connecting right now, so open it.
            let approval = NotificationCenter.default.addObserver(forName: .ghostherdrLoginApproval, object: nil, queue: .main) { note in
                guard let parts = note.object as? [String], parts.count == 2, parts[0] == value, let url = URL(string: parts[1]) else { return }
                MainActor.assumeIsolated {
                    self?.show(nil, "Approve this login in your browser (Tailscale SSH asks to confirm it). Waiting…", spinning: true)
                    NSWorkspace.shared.open(url)
                }
            }
            defer { NotificationCenter.default.removeObserver(approval) }
            let result: Result<SSHTunnel.Probe, Error> = await Task.detached { Result { try tunnel.probe() } }.value
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard !Task.isCancelled, let self, self.target.stringValue.trimmingCharacters(in: .whitespaces) == value else { return }
            switch result {
            case let .success(probe):
                if probe.herdrBinary == nil {
                    self.show(false, "Reached \(value) (\(ms) ms), but herdr isn’t installed there. Install it, or run herdr machine add \(value) in a terminal.")
                } else if !probe.running {
                    self.show(true, "Reached \(value) · herdr \(probe.version ?? "") is installed but not running. Connecting starts it.")
                    self.connect.isEnabled = true
                } else {
                    self.show(true, "Reached \(value) · herdr \(probe.version ?? "") · \(ms) ms")
                    self.connect.isEnabled = true
                }
            case let .failure(error):
                self.show(false, "Can’t reach \(value): \(error)")
            }
        }
    }

    private func show(_ ok: Bool?, _ text: String, spinning: Bool = false) {
        status.stringValue = text
        status.textColor = ok == false ? .systemOrange : (ok == true ? .labelColor : .secondaryLabelColor)
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusIcon.isHidden = ok == nil
        statusIcon.image = NSImage(systemSymbolName: ok == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = ok == true ? .systemGreen : .systemOrange
    }

    // MARK: - Buttons

    @objc private func connectClicked() {
        let value = target.stringValue.trimmingCharacters(in: .whitespaces)
        let sessionName = session.stringValue.trimmingCharacters(in: .whitespaces)
        guard let machine = manager.add(target: value, name: name.stringValue, session: sessionName.isEmpty ? nil : sessionName) else { return }
        close()
        // A probe that found herdr installed but stopped: start it once connected fails.
        let token = machine.observe { [weak machine] in
            if machine?.status == .notRunning { machine?.startServer() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            machine.removeObserver(token)
        }
        onConnect(machine)
    }

    @objc private func cancelClicked() { close() }

    private func close() {
        checkTask?.cancel()
        panel.sheetParent?.endSheet(panel)
    }
}
