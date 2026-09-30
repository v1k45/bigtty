import AppKit
import GhosttyTerminal

/// Colors for the native look. Panes use the Ghostty background; the window
/// around them (sidebar, gaps) is a step lighter in dark mode and a step
/// darker in light mode, like a source list around content. Text uses the
/// system label colors and the accent is the user's macOS accent color.
@MainActor
struct Theme {
    /// Terminal and pane background.
    let pane: NSColor
    /// Window, sidebar and the gaps between panes.
    let window: NSColor
    /// Selected sidebar card.
    let card: NSColor
    /// Selected row inside a card, chips.
    let cardStrong: NSColor
    /// Hairlines.
    let separator: NSColor
    /// Text fields drawn on panes (address bar).
    let field: NSColor
    let isDark: Bool

    var accent: NSColor { .controlAccentColor }
    var accentWash: NSColor { NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.16 : 0.12) }
    var accentLine: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.5) }

    /// The theme of the most recently themed window, for views that draw
    /// without holding a reference to their controller.
    static var current: Theme?

    init(controller: TerminalController) {
        let c = controller.backgroundColor
        let bg = NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
        let luminance = (0.2126 * Double(c.red) + 0.7152 * Double(c.green) + 0.0722 * Double(c.blue)) / 255
        isDark = luminance < 0.5
        let toward: NSColor = isDark ? .white : .black
        func mix(_ f: CGFloat) -> NSColor { bg.blended(withFraction: f, of: toward) ?? bg }
        pane = bg
        if isDark {
            window = mix(0.04)
            card = mix(0.10)
            cardStrong = mix(0.16)
            separator = mix(0.12)
            field = mix(0.10)
        } else {
            window = mix(0.08)
            card = mix(0.14)
            cardStrong = mix(0.20)
            separator = mix(0.15)
            field = mix(0.07)
        }
    }

    // Kept for code that still asks for the old names.
    var background: NSColor { pane }
    var chrome: NSColor { window }
    var sidebar: NSColor { window }
    var divider: NSColor { separator }
}
