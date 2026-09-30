import AppKit

extension NSAttributedString.Key {
    /// Fills the whole line width behind a paragraph (diff added/removed).
    static let lineBackground = NSAttributedString.Key("ghrLineBackground")
    /// The number to show in the gutter for this line (diffs use old/new).
    static let gutterLabel = NSAttributedString.Key("ghrGutterLabel")
}

/// A read-only, selectable monospaced text view with a line-number gutter.
/// Shows source files (highlighted) and unified diffs.
@MainActor
final class CodeView: NSView {
    let scrollView = NSScrollView()
    let textView: NSTextView
    private let gutter: LineGutter
    private(set) var path: String?
    private let message = NSTextField(labelWithString: "")
    var dark = true { didSet { applyColors() } }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let layout = BackgroundLayoutManager()
        storage.addLayoutManager(layout)
        // No wrapping: code scrolls horizontally.
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = NSTextView(frame: .zero, textContainer: container)
        gutter = LineGutter()
        super.init(frame: frame)
        clipsToBounds = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.height]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        gutter.textView = textView
        addSubview(gutter)
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.gutter.needsDisplay = true } }

        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        addSubview(message)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: LineGutter.width, height: bounds.height)
        scrollView.frame = NSRect(x: LineGutter.width, y: 0, width: max(0, bounds.width - LineGutter.width), height: bounds.height)
        gutter.needsDisplay = true
        message.frame = NSRect(x: 12, y: bounds.midY - 20, width: bounds.width - 24, height: 40)
    }

    private func applyColors() {
        let background = Theme.current?.background ?? .textBackgroundColor
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        gutter.background = Theme.current?.chrome ?? .controlBackgroundColor
        gutter.needsDisplay = true
    }

    func showMessage(_ text: String) {
        path = nil
        textView.string = ""
        message.stringValue = text
        message.isHidden = false
        gutter.needsDisplay = true
    }

    /// Loads and highlights a file, keeping the scroll position on reloads.
    func showFile(_ path: String) {
        let reload = path == self.path
        let visible = scrollView.contentView.bounds.origin
        self.path = path
        message.isHidden = true
        guard let data = FileManager.default.contents(atPath: path) else {
            showMessage("Can't read \((path as NSString).lastPathComponent)")
            return
        }
        if data.count > 4_000_000 {
            showMessage("\((path as NSString).lastPathComponent) is \(data.count / 1_000_000) MB; too large to show")
            return
        }
        if data.prefix(8000).contains(0) {
            showMessage("\((path as NSString).lastPathComponent) is a binary file")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        let storage = textView.textStorage!
        storage.setAttributedString(NSAttributedString(string: text))
        SyntaxHighlighter.highlight(storage, path: path, palette: .make(dark: dark), font: Self.font)
        applyColors()
        if reload { textView.scroll(visible) } else { textView.scroll(.zero) }
        gutter.needsDisplay = true
    }

    func showAttributed(_ text: NSAttributedString, identity: String) {
        let reload = identity == path
        let visible = scrollView.contentView.bounds.origin
        path = identity
        message.isHidden = true
        textView.textStorage?.setAttributedString(text)
        applyColors()
        if reload { textView.scroll(visible) } else { textView.scroll(.zero) }
        gutter.needsDisplay = true
    }

    /// Scrolls so `line` (1-based) is near the top and flashes it.
    func reveal(line: Int) {
        let text = textView.string as NSString
        var index = 0
        var current = 1
        while current < line, index < text.length {
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            current += 1
        }
        let range = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }
}

/// Draws `.lineBackground` across the full width of each line fragment.
private final class BackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.lineBackground, in: chars) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    color.setFill()
                    var fill = rect.offsetBy(dx: origin.x, dy: origin.y)
                    fill.origin.x = 0
                    fill.size.width = max(self.firstTextView?.bounds.width ?? 0, self.usedRect(for: container).width + 20)
                    fill.fill()
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Line numbers, or per-line `.gutterLabel`s when the text has them. A
/// plain view beside the scroll view (a ruler overlapped the text), kept in
/// step with its scroll position.
private final class LineGutter: NSView {
    static let width: CGFloat = 44
    weak var textView: NSTextView?
    var background: NSColor = .controlBackgroundColor

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        background.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        guard text.length > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var number = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: chars.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            number += 1
        }
        let inset = textView.textContainerInset.height
        var index = chars.location
        while index < max(NSMaxRange(chars), chars.location + 1), index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Text view coordinates are flipped like ours; shift by the scroll offset.
            let y = rect.minY + inset - visible.minY
            let label = (textView.textStorage?.attribute(.gutterLabel, at: lineRange.location, effectiveRange: nil) as? String) ?? "\(number)"
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: Self.width - size.width - 6, y: y + (rect.height - size.height) / 2), withAttributes: attributes)
            number += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
    }
}
