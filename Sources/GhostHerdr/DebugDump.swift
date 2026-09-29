import AppKit
import HerdrKit

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

    /// Renders the key window into a PNG without screen-recording access.
    private static func writeWindowSnapshot(to path: String) {
        guard let view = (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func install(describe: @escaping @MainActor () -> String) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let path = ProcessInfo.processInfo.environment["GHOSTHERDR_DEBUG_DUMP"]
                    ?? NSTemporaryDirectory() + "ghostherdr-debug.txt"
                try? describe().write(toFile: path, atomically: true, encoding: .utf8)
                writeWindowSnapshot(to: (path as NSString).deletingPathExtension + ".png")
            }
        }
        source.resume()
        self.source = source
    }
}
