import AppKit
import WebKit

/// ⌘F in a browser pane. The page is searched by a script in the app's own
/// content world (out of the page's reach), which marks matches with the
/// CSS Custom Highlight API, so the page's DOM isn't touched and the bar
/// can say "3 of 12" like the other panes. Case-insensitive.
@MainActor
final class BrowserFinder: FindDriver {
    private weak var browser: BrowserPaneView?
    var onFindStatus: ((FindStatus) -> Void)?
    var findBarInset: CGFloat { BrowserPaneView.toolbarHeight }
    var findsUpward: Bool { false }
    var findFocusView: NSView { browser?.webView ?? NSView() }
    private var query = ""
    private var generation = 0

    init(browser: BrowserPaneView) {
        self.browser = browser
    }

    func find(_ query: String) {
        self.query = query
        run("return bttyFind.find(query)", ["query": query])
    }

    func findNext(backwards: Bool) {
        guard !query.isEmpty else { return }
        run("return bttyFind.step(back, query)", ["back": backwards, "query": query])
    }

    func endFind() {
        query = ""
        run("return bttyFind.clear()", [:], report: false)
    }

    /// A new page loaded under the open bar: search it too.
    func pageLoaded() {
        if !query.isEmpty { find(query) }
    }

    func selectionForFind(_ done: @escaping (String?) -> Void) {
        // In the app's world: the page can't swap getSelection out.
        browser?.webView.evaluateJavaScript("String(window.getSelection() || '')", in: nil, in: BrowserPaneView.automationWorld) { result in
            MainActor.assumeIsolated { done((try? result.get() as? String).flatMap { $0.isEmpty ? nil : $0 }) }
        }
    }

    private func run(_ body: String, _ arguments: [String: Any], report: Bool = true) {
        guard let webView = browser?.webView else { return }
        generation += 1
        let generation = generation
        webView.callAsyncJavaScript(Self.script + "\n" + body, arguments: arguments, in: nil, in: BrowserPaneView.automationWorld) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, report, generation == self.generation else { return }
                switch result {
                case let .success(value):
                    let info = value as? [String: Any]
                    let total = (info?["total"] as? NSNumber)?.intValue ?? 0
                    let current = (info?["current"] as? NSNumber)?.intValue
                    self.onFindStatus?(self.query.isEmpty ? .idle : .matches(current: current, total: total))
                case .failure:
                    self.onFindStatus?(.unavailable("Can’t search this page"))
                }
            }
        }
    }

    /// Defines `bttyFind` once per page (in the app's world).
    static let script = """
    if (!window.bttyFind) window.bttyFind = (() => {
      const LIMIT = 5000;
      let ranges = [], index = -1, sheet = null;
      const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'TEXTAREA', 'SELECT', 'OPTION']);
      function style() {
        if (sheet || !window.CSSStyleSheet) return;
        try {
          sheet = new CSSStyleSheet();
          sheet.replaceSync('::highlight(btty-find){background-color:rgba(255,214,10,.45);color:inherit}' +
            '::highlight(btty-find-current){background-color:#ff9f0a;color:#000}');
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        } catch (_) {}
      }
      function visible(el, cache) {
        if (cache.has(el)) return cache.get(el);
        let v = true;
        if (el.checkVisibility) v = el.checkVisibility({ visibilityProperty: true, opacityProperty: false });
        else { const r = el.getClientRects(); v = r.length > 0; }
        cache.set(el, v);
        return v;
      }
      function paint() {
        if (!window.CSS || !CSS.highlights) return;
        CSS.highlights.delete('btty-find');
        CSS.highlights.delete('btty-find-current');
        if (!ranges.length) return;
        style();
        CSS.highlights.set('btty-find', new Highlight(...ranges.filter((_, i) => i !== index)));
        if (index >= 0) CSS.highlights.set('btty-find-current', new Highlight(ranges[index]));
      }
      function reveal() {
        const range = ranges[index];
        if (!range) return;
        const el = range.startContainer.parentElement;
        let rect = range.getBoundingClientRect();
        if (rect.top < 0 || rect.bottom > innerHeight || rect.left < 0 || rect.right > innerWidth) {
          if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          rect = range.getBoundingClientRect();
          if (rect.top < 0 || rect.bottom > innerHeight) window.scrollBy(0, rect.top - innerHeight / 2);
        }
      }
      function status() { return { total: ranges.length, current: index >= 0 ? index : null }; }
      function collect(query) {
        ranges = [];
        const needle = query.toLowerCase();
        if (!needle || !document.body) return;
        const cache = new Map();
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const parent = node.parentElement;
            if (!parent || skip.has(parent.tagName) || !node.data.trim()) return NodeFilter.FILTER_REJECT;
            return visible(parent, cache) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
          }
        });
        for (let node = walker.nextNode(); node && ranges.length < LIMIT; node = walker.nextNode()) {
          const text = node.data.toLowerCase();
          if (text.length !== node.data.length) continue;
          for (let at = text.indexOf(needle); at >= 0 && ranges.length < LIMIT; at = text.indexOf(needle, at + needle.length)) {
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + needle.length);
            ranges.push(range);
          }
        }
      }
      return {
        find(query) {
          collect(query);
          // The first match on screen or below it.
          index = ranges.findIndex(r => r.getBoundingClientRect().bottom >= 0);
          if (index < 0 && ranges.length) index = 0;
          paint(); reveal();
          return status();
        },
        step(back, query) {
          // The page may have changed since: drop matches that went away,
          // and look again if none are left.
          ranges = ranges.filter(r => r.startContainer.isConnected);
          if (!ranges.length) { collect(query); index = -1; }
          if (!ranges.length) return status();
          if (index < 0) index = back ? ranges.length - 1 : 0;
          else index = back ? (index - 1 + ranges.length) % ranges.length : (index + 1) % ranges.length;
          paint(); reveal();
          return status();
        },
        clear() { ranges = []; index = -1; paint(); return status(); }
      };
    })();
    """
}
