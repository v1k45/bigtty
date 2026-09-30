import AppKit
import HerdrKit
import WebKit

/// `kill -USR1 <pid>` writes the app's state to
/// `$TMPDIR/ghostherdr-debug.txt` (or `GHOSTHERDR_DEBUG_DUMP`), including
/// the text each terminal surface is showing.
@MainActor
enum DebugDump {
    private static var source: DispatchSourceSignal?
    private static var typeSource: DispatchSourceSignal?

    /// `kill -USR2 <pid>` pastes `$TMPDIR/ghostherdr-type.txt` (or
    /// `GHOSTHERDR_DEBUG_TYPE`) into the focused terminal, exercising the
    /// same input path as the keyboard.
    static func installTyping(target: @escaping @MainActor () -> HerdrTerminalView?) {
        signal(SIGUSR2, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let path = ProcessInfo.processInfo.environment["GHOSTHERDR_DEBUG_TYPE"]
                    ?? NSTemporaryDirectory() + "ghostherdr-type.txt"
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
        let webViews = allSubviews(of: view).compactMap { $0 as? WKWebView }.filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
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

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    static func install(describe: @escaping @MainActor () -> String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let path = ProcessInfo.processInfo.environment["GHOSTHERDR_DEBUG_DUMP"]
                    ?? NSTemporaryDirectory() + "ghostherdr-debug.txt"
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
