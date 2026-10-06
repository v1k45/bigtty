import AppKit

extension NSAttributedString.Key {
    /// Fills the whole line width behind a paragraph (diff added/removed).
    static let lineBackground = NSAttributedString.Key("bttyLineBackground")
    /// The number to show in the gutter for this line (diffs use old/new).
    static let gutterLabel = NSAttributedString.Key("bttyGutterLabel")
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
        // ⌘F opens the pane's find bar (`finder`), the same in every pane.
        textView.usesFindBar = false
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
        // Multi-line diagnostics, selectable so they can be copied.
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.isSelectable = true
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
        message.preferredMaxLayoutWidth = max(0, bounds.width - 24)
        let height = min(bounds.height - 24, max(40, message.fittingSize.height))
        message.frame = NSRect(x: 12, y: bounds.midY - height / 2, width: bounds.width - 24, height: height)
    }

    private func applyColors() {
        let background = Theme.current?.background ?? .textBackgroundColor
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        gutter.background = Theme.current?.chrome ?? .controlBackgroundColor
        gutter.needsDisplay = true
    }

    private var finderStorage: CodeFinder?
    /// ⌘F in the file viewer.
    var finder: CodeFinder {
        if let finderStorage { return finderStorage }
        let finder = CodeFinder(code: self)
        finderStorage = finder
        return finder
    }

    func showMessage(_ text: String) {
        path = nil
        textView.string = ""
        finderStorage?.textChanged()
        message.stringValue = text
        message.isHidden = false
        needsLayout = true
        gutter.needsDisplay = true
    }

    /// Highlights a file's contents, keeping the scroll position on reloads.
    /// Contents longer than `limit` are refused as too large.
    func showFile(_ path: String, data: Data, limit: Int) {
        let reload = path == self.path
        let visible = scrollView.contentView.bounds.origin
        self.path = path
        message.isHidden = true
        if data.count > limit {
            showMessage("\((path as NSString).lastPathComponent) is over \(limit / 1_000_000) MB; too large to show")
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
        finderStorage?.textChanged()
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
        finderStorage?.textChanged()
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

/// Find in the shown file or diff: every match marked, the current one
/// stronger and scrolled to. Case-insensitive.
@MainActor
final class CodeFinder: FindDriver {
    private weak var code: CodeView?
    var onFindStatus: ((FindStatus) -> Void)?
    var findBarInset: CGFloat { FilesPaneView.toolbarHeight }
    var findsUpward: Bool { false }
    var findFocusView: NSView { code?.textView ?? NSView() }
    private var query = ""
    private(set) var ranges: [NSRange] = []
    private(set) var index: Int?

    private static let matchColor = NSColor.systemYellow.withAlphaComponent(0.35)
    private static let currentColor = NSColor.systemOrange.withAlphaComponent(0.75)

    init(code: CodeView) {
        self.code = code
    }

    func find(_ query: String) {
        self.query = query
        search(from: visibleStart, reveal: true)
    }

    func findNext(backwards: Bool) {
        guard !ranges.isEmpty else { return search(from: visibleStart, reveal: true) }
        let count = ranges.count
        index = index.map { (backwards ? $0 - 1 + count : $0 + 1) % count } ?? (backwards ? count - 1 : 0)
        mark()
        reveal()
    }

    func endFind() {
        query = ""
        search(from: 0, reveal: false)
    }

    /// New contents (a reload, another file): search them, staying near
    /// where the current match was.
    func textChanged() {
        guard !query.isEmpty else { return }
        search(from: index.map { ranges[$0].location } ?? visibleStart, reveal: false)
    }

    func selectionForFind(_ done: @escaping (String?) -> Void) {
        guard let textView = code?.textView else { return done(nil) }
        let range = textView.selectedRange()
        done(range.length > 0 ? (textView.string as NSString).substring(with: range) : nil)
    }

    private var visibleStart: Int {
        guard let textView = code?.textView, let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
    }

    private func search(from location: Int, reveal shouldReveal: Bool) {
        guard let textView = code?.textView else { return }
        ranges = TextSearch.ranges(of: query, in: textView.string as NSString)
        index = TextSearch.index(after: location, in: ranges)
        mark()
        if shouldReveal { reveal() }
        onFindStatus?(query.isEmpty ? .idle : .matches(current: index, total: ranges.count))
    }

    private func mark() {
        guard let textView = code?.textView, let layout = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for (i, range) in ranges.enumerated() where NSMaxRange(range) <= all.length {
            layout.addTemporaryAttribute(.backgroundColor, value: i == index ? Self.currentColor : Self.matchColor, forCharacterRange: range)
        }
        onFindStatus?(query.isEmpty ? .idle : .matches(current: index, total: ranges.count))
    }

    private func reveal() {
        guard let textView = code?.textView, let index, ranges.indices.contains(index) else { return }
        textView.scrollRangeToVisible(ranges[index])
        textView.showFindIndicator(for: ranges[index])
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
