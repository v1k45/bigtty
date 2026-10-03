import AppKit

/// ⌘Q quits only when held, so a slip of the keyboard doesn't close the
/// app. Quit chosen with the mouse (menu, Dock) still quits at once.
@MainActor
enum HoldToQuit {
    static let duration: TimeInterval = 0.9

    private static var panel: NSPanel?
    private static var bar: CALayer?
    private static var monitor: Any?
    private static var quitTimer: Timer?
    private static var hideTimer: Timer?

    static func begin() {
        guard let event = NSApp.currentEvent, event.type == .keyDown else {
            NSApp.terminate(nil)
            return
        }
        // Key repeats while held come back here; the first press runs it.
        guard !event.isARepeat, quitTimer == nil else { return }
        hideTimer?.invalidate()
        show()
        quitTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated { end(quit: true) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { event in
            let releasedQ = event.type == .keyUp && event.charactersIgnoringModifiers?.lowercased() == "q"
            let releasedCommand = event.type == .flagsChanged && !event.modifierFlags.contains(.command)
            if releasedQ || releasedCommand { end(quit: false) }
            return event
        }
    }

    private static func end(quit: Bool) {
        quitTimer?.invalidate()
        quitTimer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if quit {
            NSApp.terminate(nil)
            return
        }
        // Let go too soon: the hint stays long enough to read.
        bar?.removeAllAnimations()
        bar?.bounds.size.width = 0
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated { fade(in: false) }
        }
    }

    private static func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        let frame = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        if !panel.isVisible || panel.alphaValue < 1 { fade(in: true) }

        // The bar fills while ⌘Q is held.
        guard let bar, let full = bar.superlayer?.bounds.width else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds.size.width = full
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = full
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        bar.add(grow, forKey: "grow")
    }

    private static func fade(in appearing: Bool) {
        guard let panel else { return }
        if appearing {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = appearing ? 0.12 : 0.2
            panel.animator().alphaValue = appearing ? 1 : 0
        }, completionHandler: {
            MainActor.assumeIsolated { if !appearing, panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private static func makePanel() -> NSPanel {
        let size = NSSize(width: 260, height: 112)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        // A HUD reads the same over any window, light or dark.
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.contentView = background
        // Tinted so it looks the same over a light or a dark window.
        let tint = NSView(frame: background.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.55).cgColor
        background.addSubview(tint)

        // ⌘ Q keycaps, centered.
        let keys = ["⌘", "Q"].map { KeyCap($0, size: 17) }
        let widths = keys.map { max($0.intrinsicContentSize.width, 34) }
        let gap: CGFloat = 6
        var x = (size.width - widths.reduce(0, +) - gap) / 2
        for (key, width) in zip(keys, widths) {
            key.frame = NSRect(x: x, y: 58, width: width, height: 34)
            background.addSubview(key)
            x += width + gap
        }

        let label = NSTextField(labelWithString: "Hold to quit bigtty")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 28, width: size.width, height: 18)
        background.addSubview(label)

        let track = NSView(frame: NSRect(x: 28, y: 16, width: size.width - 56, height: 4))
        track.wantsLayer = true
        track.layer?.cornerRadius = 2
        track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        background.addSubview(track)
        let fill = CALayer()
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: 4)
        fill.cornerRadius = 2
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        track.layer?.addSublayer(fill)
        bar = fill
        return panel
    }
}
