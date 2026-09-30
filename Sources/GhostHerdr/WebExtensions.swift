import AppKit
import WebKit

/// Web extensions (Safari/Chrome MV3, e.g. uBlock Origin Lite) for browser
/// panes, through WebKit's extension support (macOS 15.4+). Extensions are
/// unpacked folders in ~/Library/Application Support/GhostHerdr/Extensions;
/// every browser pane is a tab of one extension "window".
@MainActor
enum WebExtensions {
    /// Where unpacked extensions live, one folder each.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostHerdr/Extensions", isDirectory: true)
    }

    /// The shared controller, for web view configurations; nil before macOS 15.4.
    static var controller: AnyObject? {
        guard #available(macOS 15.4, *) else { return nil }
        return WebExtensionHost.shared.controller
    }

    /// Hooks a new web view's configuration up to the extensions.
    static func configure(_ config: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        config.webExtensionController = WebExtensionHost.shared.controller
    }

    /// For the debug dump: contexts, their permissions and errors.
    static var debugDetail: String {
        guard #available(macOS 15.4, *) else { return "" }
        let host = WebExtensionHost.shared
        return host.controller.extensionContexts.map { context in
            let ext = context.webExtension
            return "[\(ext.displayName ?? "?") loaded=\(context.isLoaded) allURLs=\(context.hasAccessToAllURLs) dnr=\(context.hasPermission(.declarativeNetRequest)) rules=\(context.hasContentModificationRules) errors=\(context.errors.map(\.localizedDescription))]"
        }.joined(separator: " ")
    }

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// Loads (or reloads) every extension in the folder.
    static func start() {
        guard #available(macOS 15.4, *) else { return }
        WebExtensionHost.shared.loadAll()
    }

    static func tabOpened(_ pane: BrowserPaneView) {
        guard #available(macOS 15.4, *) else { return }
        WebExtensionHost.shared.tabOpened(pane)
    }

    static func tabClosed(_ pane: BrowserPaneView) {
        guard #available(macOS 15.4, *) else { return }
        WebExtensionHost.shared.tabClosed(pane)
    }

    static func tabActivated(_ pane: BrowserPaneView) {
        guard #available(macOS 15.4, *) else { return }
        WebExtensionHost.shared.tabActivated(pane)
    }

    static func tabChanged(_ pane: BrowserPaneView) {
        guard #available(macOS 15.4, *) else { return }
        WebExtensionHost.shared.tabChanged(pane)
    }

    /// Loaded extensions with a toolbar action: name, icon, and a click.
    static func actions(for pane: BrowserPaneView) -> [(name: String, icon: NSImage?, badge: String, perform: () -> Void)] {
        guard #available(macOS 15.4, *) else { return [] }
        return WebExtensionHost.shared.actions(for: pane)
    }

    /// Names of loaded extensions, and problems loading the others.
    static var status: [String] {
        guard #available(macOS 15.4, *) else { return ["Needs macOS 15.4 or later"] }
        return WebExtensionHost.shared.status
    }

    // MARK: - uBlock Origin Lite

    /// Downloads the latest uBlock Origin Lite (Safari build) from its
    /// GitHub releases into the extensions folder, then loads it.
    static func installUBlockLite(completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        Task.detached {
            do {
                let api = URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest")!
                let (data, _) = try await URLSession.shared.data(from: api)
                let release = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let assets = release?["assets"] as? [[String: Any]] ?? []
                guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".safari.zip") == true }),
                      let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                      let version = release?["tag_name"] as? String
                else { throw InstallError.notFound }
                let (zip, _) = try await URLSession.shared.download(from: link)
                let target = await MainActor.run { folder.appendingPathComponent("uBOLite", isDirectory: true) }
                let fm = FileManager.default
                let staging = fm.temporaryDirectory.appendingPathComponent("uBOLite-\(UUID().uuidString)")
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, staging.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      fm.fileExists(atPath: staging.appendingPathComponent("manifest.json").path)
                else { throw InstallError.badArchive }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: staging, to: target)
                await MainActor.run {
                    start()
                    completion(.success(version))
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    enum InstallError: LocalizedError {
        case notFound, badArchive
        var errorDescription: String? {
            switch self {
            case .notFound: "No Safari build in the latest uBlock Origin Lite release."
            case .badArchive: "The download didn't contain an extension."
            }
        }
    }
}

extension Notification.Name {
    /// Extensions were loaded or unloaded: toolbars refresh their buttons.
    static let ghostherdrExtensionsChanged = Notification.Name("GhostHerdrExtensionsChanged")
}

// MARK: - Host

@available(macOS 15.4, *)
@MainActor
final class WebExtensionHost: NSObject, WKWebExtensionControllerDelegate {
    static let shared = WebExtensionHost()

    let controller: WKWebExtensionController
    private let window = ExtensionWindow()
    private(set) var status: [String] = []
    private var popover: NSPopover?

    override init() {
        // Persistent storage per extension (settings, filter choices).
        controller = WKWebExtensionController(configuration: .default())
        super.init()
        controller.delegate = self
    }

    func loadAll() {
        for context in controller.extensionContexts { try? controller.unload(context) }
        status = []
        let fm = FileManager.default
        let folder = WebExtensions.folder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs where fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) {
            Task {
                do {
                    let ext = try await WKWebExtension(resourceBaseURL: dir)
                    let context = WKWebExtensionContext(for: ext)
                    // A stable id keeps the extension's storage across launches.
                    context.uniqueIdentifier = "dev.ghostherdr.ext." + dir.lastPathComponent
                    for permission in ext.requestedPermissions.union(ext.optionalPermissions) {
                        context.setPermissionStatus(.grantedExplicitly, for: permission)
                    }
                    // Content blockers need every site.
                    context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
                    for pattern in ext.allRequestedMatchPatterns {
                        context.setPermissionStatus(.grantedExplicitly, for: pattern)
                    }
                    context.isInspectable = true
                    try controller.load(context)
                    status.append("\(ext.displayName ?? dir.lastPathComponent) \(ext.version ?? "")")
                    for pane in BrowserRegistry.shared.all.map(\.view) { controller.didOpenTab(pane) }
                    if !ext.errors.isEmpty {
                        NSLog("ghostherdr: extension \(dir.lastPathComponent) warnings: \(ext.errors)")
                    }
                } catch {
                    status.append("\(dir.lastPathComponent): \(error.localizedDescription)")
                    NSLog("ghostherdr: extension \(dir.lastPathComponent) failed: \(error)")
                }
                NotificationCenter.default.post(name: .ghostherdrExtensionsChanged, object: nil)
            }
        }
        NotificationCenter.default.post(name: .ghostherdrExtensionsChanged, object: nil)
    }

    // MARK: Tabs

    func tabOpened(_ pane: BrowserPaneView) { controller.didOpenTab(pane) }

    func tabClosed(_ pane: BrowserPaneView) { controller.didCloseTab(pane, windowIsClosing: false) }

    func tabActivated(_ pane: BrowserPaneView) {
        let previous = window.active
        guard previous !== pane else { return }
        window.active = pane
        controller.didActivateTab(pane, previousActiveTab: previous)
    }

    func tabChanged(_ pane: BrowserPaneView) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: pane)
    }

    func actions(for pane: BrowserPaneView) -> [(name: String, icon: NSImage?, badge: String, perform: () -> Void)] {
        controller.extensionContexts.compactMap { context in
            guard let action = context.action(for: pane) else { return nil }
            let name = context.webExtension.displayName ?? "Extension"
            return (name, action.icon(for: NSSize(width: 16, height: 16)), action.badgeText, { [weak pane] in
                guard let pane else { return }
                WebExtensionHost.shared.tabActivated(pane)
                context.performAction(for: pane)
            })
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_: WKWebExtensionController, openWindowsFor _: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_: WKWebExtensionController, focusedWindowFor _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(
        _: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let web = action.popupWebView,
              let pane = (action.associatedTab as? BrowserPaneView) ?? window.active,
              let anchor = pane.extensionAnchor
        else {
            completionHandler(nil)
            return
        }
        popover?.close()
        let controller = NSViewController()
        web.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        controller.view = web
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 360, height: 520)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        self.popover = popover
        completionHandler(nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(patterns, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in _: (any WKWebExtensionTab)?, for _: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for _: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        // The dashboard (settings) and similar pages: in the default browser
        // can't load extension URLs, so a browser pane beside the active one.
        if let url = configuration.url {
            NotificationCenter.default.post(name: .ghostherdrExtensionOpenURL, object: url.absoluteString)
        }
        completionHandler(nil, nil)
    }

    func webExtensionController(
        _: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = context.optionsPageURL {
            NotificationCenter.default.post(name: .ghostherdrExtensionOpenURL, object: url.absoluteString)
        }
        completionHandler(nil)
    }
}

extension Notification.Name {
    /// An extension asked to open a page (its settings): object is the URL.
    static let ghostherdrExtensionOpenURL = Notification.Name("GhostHerdrExtensionOpenURL")
}

/// Every browser pane, as one window of tabs.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var active: BrowserPaneView?

    func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        BrowserRegistry.shared.all.map(\.view)
    }

    func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        active ?? BrowserRegistry.shared.lastFocused.flatMap { BrowserRegistry.shared.existing($0) }
    }

    func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for _: WKWebExtensionContext) -> Bool { false }
}

@available(macOS 15.4, *)
extension BrowserPaneView: WKWebExtensionTab {
    func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        WebExtensionHost.shared.windowObject
    }

    func webView(for _: WKWebExtensionContext) -> WKWebView? { webView }
    func url(for _: WKWebExtensionContext) -> URL? { webView.url }
    func title(for _: WKWebExtensionContext) -> String? { webView.title }
    func isLoadingComplete(for _: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func isSelected(for _: WKWebExtensionContext) -> Bool { WebExtensionHost.shared.windowObject.active === self }

    func loadURL(_ url: URL, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        navigate(to: url)
        completionHandler(nil)
    }

    func reload(fromOrigin _: Bool, for _: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView.reload()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension WebExtensionHost {
    var windowObject: ExtensionWindow { window }
}
