import AppKit
import PDFKit

/// Images and PDFs in a files pane: fit to the pane, pinch or ⌘± to zoom,
/// with the size and dimensions in a caption.
@MainActor
final class ImagePreview: NSView {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "ico", "icns", "svg"]

    static func canShow(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || ext == "pdf"
    }

    /// Whether `data` is something `show` can display.
    nonisolated static func canDecode(_ path: String, data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if (path as NSString).pathExtension.lowercased() == "pdf" { return PDFDocument(data: data) != nil }
        return NSImage(data: data) != nil
    }

    private let scroll = NSScrollView()
    private let imageView = NSImageView()
    private let pdfView = PDFView()
    private let caption = NSTextField(labelWithString: "")
    private(set) var path: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.1
        scroll.maxMagnification = 16
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .clear
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        for view in [scroll, pdfView, caption] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Shows (or reloads, keeping zoom) the contents of `path`.
    func show(_ path: String, data: Data) {
        let reload = path == self.path
        self.path = path
        let url = URL(fileURLWithPath: path)
        let bytes = data.count
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        if url.pathExtension.lowercased() == "pdf" {
            scroll.isHidden = true
            pdfView.isHidden = false
            pdfView.document = PDFDocument(data: data)
            let pages = pdfView.document?.pageCount ?? 0
            caption.stringValue = "\(url.lastPathComponent) · \(pages) page\(pages == 1 ? "" : "s") · \(size)"
        } else {
            pdfView.isHidden = true
            scroll.isHidden = false
            let image = NSImage(data: data)
            imageView.image = image
            let rep = image?.representations.first
            let pixels = rep.map { "\($0.pixelsWide) × \($0.pixelsHigh)" } ?? "unreadable"
            caption.stringValue = "\(url.lastPathComponent) · \(pixels) · \(size)"
            if !reload { scroll.magnification = 1 }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.current?.pane.cgColor
        let area = NSRect(x: 12, y: 30, width: bounds.width - 24, height: bounds.height - 42)
        scroll.frame = area
        pdfView.frame = area
        // Fit the image to the pane; magnification zooms from there.
        imageView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        caption.frame = NSRect(x: 0, y: 8, width: bounds.width, height: 15)
    }
}
