import AppKit
import HerdrKit
import WebKit

/// `kill -USR1 <pid>` writes the app's state to
/// `$TMPDIR/bigtty-debug.txt` (or `BIGTTY_DEBUG_DUMP`), including
/// the text each terminal surface is showing.
@MainActor
enum DebugDump {
    private static var source: DispatchSourceSignal?
    private static var typeSource: DispatchSourceSignal?

    /// `kill -USR2 <pid>` pastes `$TMPDIR/bigtty-type.txt` (or
    /// `BIGTTY_DEBUG_TYPE`) into the focused terminal, exercising the
    /// same input path as the keyboard.
    static func installTyping(target: @escaping @MainActor () -> HerdrTerminalView?) {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let path = ProcessInfo.processInfo.environment["BIGTTY_DEBUG_TYPE"]
                    ?? NSTemporaryDirectory() + "bigtty-type.txt"
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                // `!selector [argument]` sends a menu action to the key window
                // instead, e.g. `!newBrowserPane:` or `!openURL: https://…`.
                // `!@space selector [argument]` picks the window by space name.
                if text.hasPrefix("!") {
                    var parts = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                        .split(separator: " ", maxSplits: 1).map(String.init)
                    var window = NSApp.keyWindow ?? NSApp.orderedWindows.first
                    if parts[0].hasPrefix("@") {
                        let name = String(parts[0].dropFirst())
                        window = NSApp.orderedWindows.first { $0.title == name } ?? window
                        parts = parts.count > 1 ? parts[1].split(separator: " ", maxSplits: 1).map(String.init) : []
                    }
                    guard !parts.isEmpty else { return }
                    let argument: Any? = parts.count > 1 ? parts[1] : nil
                    let selector = Selector(parts[0])
                    let controller = window?.windowController
                    let target: AnyObject? = controller?.responds(to: selector) == true ? controller : NSApp.delegate
                    guard target?.responds(to: selector) == true else { return NSLog("bigtty: no debug action \(parts[0])") }
                    NSApp.sendAction(selector, to: target, from: argument)
                    return
                }
                if text.hasSuffix("\n") {
                    _ = target()?.paste(text: String(text.dropLast()))
                    _ = target()?.sendKey(.enter)
                } else {
                    _ = target()?.paste(text: text)
                }
            }
        }
        source.resume()
        typeSource = source
    }

    /// Renders a window into a PNG without screen-recording access. Web
    /// content lives in another process, so each web view's own snapshot is
    /// painted over its frame.
    private static func writeWindowSnapshot(of window: NSWindow?, to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Skip web views covered by a sibling drawn above them (error pages).
        let webViews = allSubviews(of: view).compactMap { $0 as? WKWebView }.filter { web in
            guard web.window != nil, !web.isHiddenOrHasHiddenAncestor, let parent = web.superview,
                  let index = parent.subviews.firstIndex(of: web) else { return false }
            return !parent.subviews[(index + 1)...].contains { !$0.isHidden && $0.frame.contains(web.frame) }
        }
        let group = DispatchGroup()
        var shots: [(NSRect, NSImage)] = []
        for webView in webViews {
            group.enter()
            let frame = webView.convert(webView.bounds, to: view)
            webView.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((frame, image)) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for (frame, image) in shots { image.draw(in: frame) }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A README-quality picture of a window: frame and traffic lights
    /// included, web content and floating panels (⌘K) painted in, corners
    /// rounded like the real window. Works while the screen is locked.
    static func writeScreenshot(of window: NSWindow, to path: String, contentOnly: Bool = false) {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let webViews = allSubviews(of: frameView).compactMap { $0 as? WKWebView }.filter { web in
            guard web.window != nil, !web.isHiddenOrHasHiddenAncestor, let parent = web.superview,
                  let index = parent.subviews.firstIndex(of: web) else { return false }
            return !parent.subviews[(index + 1)...].contains { !$0.isHidden && $0.frame.contains(web.frame) }
        }
        // Overlays drawn above web content (shortcut badges, the ⌘/ sheet):
        // painted again after the web snapshots so those don't cover them.
        let overlays: [(NSRect, NSBitmapImageRep)] = allSubviews(of: frameView).compactMap { view in
            guard view is KeyCap || view is ShortcutSheetView, !view.isHiddenOrHasHiddenAncestor,
                  !(view.superview is KeyCap), !(view is KeyCap && view.ancestorOf(ShortcutSheetView.self) != nil),
                  let overlayRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: overlayRep)
            return (view.convert(view.bounds, to: frameView), overlayRep)
        }
        // Floating panels over the window (the jump palette).
        let panels: [(NSRect, NSBitmapImageRep)] = NSApp.windows.compactMap { other in
            guard other !== window, other.isVisible, other is NSPanel, other.frame.intersects(window.frame),
                  let view = other.contentView?.superview,
                  let panelRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: panelRep)
            let origin = NSPoint(x: other.frame.minX - window.frame.minX, y: other.frame.minY - window.frame.minY)
            return (NSRect(origin: origin, size: other.frame.size), panelRep)
        }
        let group = DispatchGroup()
        var shots: [(NSRect, NSImage)] = []
        for webView in webViews {
            group.enter()
            let frame = webView.convert(webView.bounds, to: frameView)
            webView.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((frame, image)) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let size = frameView.bounds.size
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            out.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 12, yRadius: 12).addClip()
            // The window's own background, which content views don't draw.
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: size).fill()
            }
            rep.draw(in: NSRect(origin: .zero, size: size))
            for (frame, image) in shots { image.draw(in: frame) }
            for (frame, overlay) in overlays {
                NSGraphicsContext.saveGraphicsState()
                // The sheet's corners, or a badge's.
                let radius = overlay.size.width > 300 ? 16 : frame.height * 0.3
                NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
                overlay.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
            }
            // The traffic lights as an active window shows them (a render
            // of a background window draws them grey).
            let colors: [(NSWindow.ButtonType, NSColor)] = [
                (.closeButton, NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
                (.miniaturizeButton, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1)),
                (.zoomButton, NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)),
            ]
            for (kind, color) in contentOnly ? [] : colors {
                guard let button = window.standardWindowButton(kind), !button.isHidden else { continue }
                let rect = button.convert(button.bounds, to: frameView)
                let side = min(rect.width, rect.height) - 2
                let dot = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
                color.setFill()
                NSBezierPath(ovalIn: dot).fill()
                color.shadow(withLevel: 0.25)?.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
                ring.lineWidth = 0.5
                ring.stroke()
            }
            for (frame, panel) in panels {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14).addClip()
                panel.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.separatorColor.setStroke()
                let border = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: 14, yRadius: 14)
                border.lineWidth = 0.5
                border.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            var final = out
            if contentOnly, let cropped = Self.crop(out, to: window.contentLayoutRect, in: size) { final = cropped }
            try? final.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The part of a window picture below its title bar and toolbar, with
    /// rounded corners.
    private static func crop(_ rep: NSBitmapImageRep, to rect: NSRect, in size: NSSize) -> NSBitmapImageRep? {
        let scale = CGFloat(rep.pixelsWide) / size.width
        // Bitmap rows run top-down; the rect is bottom-up.
        let pixels = CGRect(x: rect.minX * scale, y: (size.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
        guard let cg = rep.cgImage?.cropping(to: pixels),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: rect.size), xRadius: 12, yRadius: 12).addClip()
        NSImage(cgImage: cg, size: rect.size).draw(in: NSRect(origin: .zero, size: rect.size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    static func install(describe: @escaping @MainActor () -> String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let path = ProcessInfo.processInfo.environment["BIGTTY_DEBUG_DUMP"]
                    ?? NSTemporaryDirectory() + "bigtty-debug.txt"
                try? describe().write(toFile: path, atomically: true, encoding: .utf8)
                let base = (path as NSString).deletingPathExtension
                writeWindowSnapshot(of: NSApp.keyWindow ?? NSApp.orderedWindows.first, to: base + ".png")
                for window in NSApp.orderedWindows {
                    let name = window.title.replacingOccurrences(of: "/", with: "_")
                    writeWindowSnapshot(of: window, to: "\(base)-\(name).png")
                }
            }
        }
        source.resume()
        self.source = source
    }
}

private extension NSView {
    /// The nearest ancestor of a type, if any.
    func ancestorOf<T: NSView>(_: T.Type) -> T? {
        var view = superview
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}
