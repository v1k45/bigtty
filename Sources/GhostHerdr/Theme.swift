import AppKit
import GhosttyTerminal

/// Window chrome derived from the Ghostty background, so the sidebar, tab
/// strip and pane headers sit on the same palette as the terminals.
@MainActor
struct Theme {
    let background: NSColor
    let chrome: NSColor
    let sidebar: NSColor
    let divider: NSColor
    let isDark: Bool

    /// The theme of the most recently themed window, for views that draw
    /// dividers without holding a reference to their controller.
    static var current: Theme?

    init(controller: TerminalController) {
        let c = controller.backgroundColor
        background = NSColor(
            srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1
        )
        let luminance = (0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)) / 255
        isDark = luminance < 0.5
        chrome = background.blended(withFraction: 0.06, of: isDark ? .white : .black) ?? background
        sidebar = background.blended(withFraction: 0.03, of: isDark ? .white : .black) ?? background
        divider = background.blended(withFraction: 0.16, of: isDark ? .white : .black) ?? .separatorColor
    }
}
