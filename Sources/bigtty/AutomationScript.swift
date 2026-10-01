// The in-page half of browser automation. It is installed in its own
// content world ("bigtty"), so pages can neither see nor tamper with it,
// and exposes `__ghr` for `BrowserAutomation` to call. The command
// vocabulary follows vercel-labs/agent-browser; the code is our own.

enum AutomationScript {
    static let source = #"""
    (() => {
      if (globalThis.__ghr) return;

      let refs = new Map();
      let nextRef = 1;

      const INTERACTIVE = new Set([
        "link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox",
        "listbox", "option", "slider", "spinbutton", "switch", "tab", "menuitem",
        "menuitemcheckbox", "menuitemradio", "treeitem",
      ]);
      const LANDMARK_TAGS = {
        NAV: "navigation", MAIN: "main", HEADER: "banner", FOOTER: "contentinfo",
        ASIDE: "complementary", FORM: "form", DIALOG: "dialog", UL: "list", OL: "list",
        LI: "listitem", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader",
        P: "paragraph", IMG: "img", ARTICLE: "article", SECTION: "region",
        OPTION: "option", SUMMARY: "button", TEXTAREA: "textbox",
      };

      function role(el) {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit.split(" ")[0];
        const tag = el.tagName;
        if (tag === "A") return el.hasAttribute("href") ? "link" : null;
        if (tag === "BUTTON") return "button";
        if (/^H[1-6]$/.test(tag)) return "heading";
        if (tag === "SELECT") return el.multiple ? "listbox" : "combobox";
        if (tag === "INPUT") {
          const type = (el.getAttribute("type") || "text").toLowerCase();
          if (type === "hidden") return null;
          if (["button", "submit", "reset", "image"].includes(type)) return "button";
          if (type === "checkbox") return "checkbox";
          if (type === "radio") return "radio";
          if (type === "range") return "slider";
          if (type === "number") return "spinbutton";
          if (type === "search") return "searchbox";
          return "textbox";
        }
        if (el.isContentEditable && el.parentElement && !el.parentElement.isContentEditable) return "textbox";
        if (tag === "SECTION" && !(el.getAttribute("aria-label") || el.getAttribute("aria-labelledby"))) return null;
        return LANDMARK_TAGS[tag] || null;
      }

      function squash(text, max = 100) {
        text = (text || "").replace(/\s+/g, " ").trim();
        return text.length > max ? text.slice(0, max - 1) + "…" : text;
      }

      function labelFor(el) {
        if (el.labels && el.labels.length) return Array.from(el.labels).map(l => l.innerText).join(" ");
        return "";
      }

      function name(el, r) {
        const labelledby = el.getAttribute("aria-labelledby");
        if (labelledby) {
          const text = labelledby.split(/\s+/).map(id => document.getElementById(id)?.innerText || "").join(" ");
          if (text.trim()) return squash(text);
        }
        const aria = el.getAttribute("aria-label");
        if (aria) return squash(aria);
        // Containers are named only explicitly; their text shows as children.
        if (["navigation", "main", "banner", "contentinfo", "complementary", "form", "list", "listitem",
             "table", "row", "region", "article", "dialog", "paragraph", "cell", "columnheader"].includes(r)) return "";
        if (["textbox", "searchbox", "combobox", "listbox", "checkbox", "radio", "slider", "spinbutton"].includes(r)) {
          return squash(labelFor(el) || el.getAttribute("placeholder") || el.getAttribute("title") || el.getAttribute("name") || "");
        }
        if (el.tagName === "INPUT") return squash(el.value || el.getAttribute("title") || "");
        if (el.tagName === "IMG") return squash(el.getAttribute("alt") || el.getAttribute("title") || "");
        return squash(el.innerText || el.textContent || el.getAttribute("title") || "");
      }

      function visible(el) {
        if (el.getAttribute("aria-hidden") === "true") return false;
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
        if (style.position !== "fixed" && el.offsetParent === null && el.tagName !== "BODY" && style.position !== "sticky") {
          return el.getClientRects().length > 0;
        }
        return true;
      }

      function refFor(el) {
        for (const [id, weak] of refs) if (weak.deref() === el) return id;
        const id = "e" + nextRef++;
        refs.set(id, new WeakRef(el));
        return id;
      }

      function attributes(el, r) {
        const parts = [];
        if (r === "heading") parts.push("level=" + (el.getAttribute("aria-level") || el.tagName.slice(1)));
        if ("checked" in el && (r === "checkbox" || r === "radio" || r === "switch")) parts.push(el.checked ? "checked" : "unchecked");
        if (el.getAttribute("aria-checked")) parts.push("checked=" + el.getAttribute("aria-checked"));
        if (el.getAttribute("aria-expanded")) parts.push("expanded=" + el.getAttribute("aria-expanded"));
        if (el.getAttribute("aria-selected") === "true" || el.selected) parts.push("selected");
        if (el.disabled || el.getAttribute("aria-disabled") === "true") parts.push("disabled");
        if (el === document.activeElement) parts.push("focused");
        if (r === "link" && el.getAttribute("href")) parts.push("href=" + squash(el.getAttribute("href"), 80));
        return parts;
      }

      function snapshot(options = {}) {
        refs = new Map();
        nextRef = 1;
        const interactiveOnly = !!options.interactive;
        const maxLines = options.maxLines || 800;
        const root = options.selector ? document.querySelector(options.selector) : document.body;
        const lines = [];
        if (!root) return "";

        function walk(el, depth) {
          if (lines.length >= maxLines) return;
          if (!(el instanceof Element) || !visible(el)) return;
          if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG"].includes(el.tagName.toUpperCase())) return;
          const r = role(el);
          const interactive = r && (INTERACTIVE.has(r) || el.hasAttribute("onclick"));
          let emitted = false;
          if (r && (!interactiveOnly || interactive)) {
            const n = name(el, r);
            const attrs = attributes(el, r);
            if (interactive) attrs.push("ref=" + refFor(el));
            let line = "  ".repeat(depth) + "- " + r + (n ? " " + JSON.stringify(n) : "");
            if (attrs.length) line += " [" + attrs.join(", ") + "]";
            if ((r === "textbox" || r === "searchbox" || r === "combobox") && "value" in el && el.value) {
              line += ": " + JSON.stringify(squash(el.value, 80));
            }
            lines.push(line);
            emitted = true;
            // Leaf-ish roles: their text is already the name.
            if (["link", "button", "heading", "textbox", "searchbox", "option", "img", "checkbox", "radio"].includes(r)) return;
          }
          const childDepth = emitted ? depth + 1 : depth;
          if (!interactiveOnly) {
            for (const node of el.childNodes) {
              if (node.nodeType === Node.TEXT_NODE) {
                const text = squash(node.textContent, 200);
                if (text && r !== "paragraph" && r !== "listitem" && r !== "cell") {
                  lines.push("  ".repeat(childDepth) + "- text: " + text);
                } else if (text && (r === "paragraph" || r === "listitem" || r === "cell") && !lines[lines.length - 1].includes(JSON.stringify(squash(el.innerText)))) {
                  lines.push("  ".repeat(childDepth) + "- text: " + text);
                }
              } else {
                walk(node, childDepth);
              }
            }
          } else {
            for (const child of el.children) walk(child, childDepth);
          }
          if (el.shadowRoot) for (const child of el.shadowRoot.children) walk(child, childDepth);
        }
        walk(root, 0);
        if (lines.length >= maxLines) lines.push("- … (truncated at " + maxLines + " lines)");
        return lines.join("\n");
      }

      function resolve(target) {
        if (target == null || target === "") throw new Error("no target given");
        const ref = String(target).replace(/^@/, "").replace(/^ref=/, "");
        if (/^e\d+$/.test(ref)) {
          const el = refs.get(ref)?.deref();
          if (!el || !el.isConnected) throw new Error("ref @" + ref + " is stale; take a new snapshot");
          return el;
        }
        let el;
        try { el = document.querySelector(target); } catch (e) { throw new Error("invalid selector: " + target); }
        if (!el) throw new Error("no element matches " + target);
        return el;
      }

      function center(el) {
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        const rect = el.getBoundingClientRect();
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      }

      function mouse(el, type, point, extra = {}) {
        const Ctor = type.startsWith("pointer") ? PointerEvent : MouseEvent;
        el.dispatchEvent(new Ctor(type, {
          bubbles: true, cancelable: true, composed: true, view: window,
          clientX: point.x, clientY: point.y, button: 0, buttons: type.endsWith("down") ? 1 : 0,
          pointerType: "mouse", isPrimary: true, ...extra,
        }));
      }

      function click(target, options = {}) {
        const el = resolve(target);
        if (el.disabled) throw new Error("element is disabled");
        const p = center(el);
        const count = options.count || 1;
        for (let i = 1; i <= count; i++) {
          mouse(el, "pointerover", p); mouse(el, "mouseover", p);
          mouse(el, "pointerdown", p); mouse(el, "mousedown", p, { detail: i });
          if (typeof el.focus === "function") el.focus({ preventScroll: true });
          mouse(el, "pointerup", p); mouse(el, "mouseup", p, { detail: i });
          el.click();
        }
        if (count === 2) mouse(el, "dblclick", p, { detail: 2 });
        return true;
      }

      function setNativeValue(el, value) {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
          : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
        if (setter) setter.call(el, value); else el.value = value;
      }

      function fill(target, text) {
        const el = resolve(target);
        el.scrollIntoView({ block: "center", behavior: "instant" });
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
          el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        } else {
          setNativeValue(el, text);
          el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
        }
        return true;
      }

      function key(el, type, k) {
        const named = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Space: 32, " ": 32 };
        const code = named[k] || (k.length === 1 ? k.toUpperCase().charCodeAt(0) : 0);
        return el.dispatchEvent(new KeyboardEvent(type, {
          key: k === "Space" ? " " : k, code: k.length === 1 ? "Key" + k.toUpperCase() : k,
          keyCode: code, which: code, bubbles: true, cancelable: true, composed: true,
        }));
      }

      function type(target, text) {
        const el = target ? resolve(target) : document.activeElement || document.body;
        if (target) el.focus();
        for (const ch of text) {
          const proceed = key(el, "keydown", ch);
          key(el, "keypress", ch);
          if (proceed) {
            if (el.isContentEditable) {
              el.textContent += ch;
            } else if ("value" in el) {
              setNativeValue(el, el.value + ch);
            }
            el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: ch }));
          }
          key(el, "keyup", ch);
        }
        if ("value" in el) el.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      }

      function press(k, target) {
        const el = target ? resolve(target) : document.activeElement || document.body;
        const proceed = key(el, "keydown", k);
        if (proceed && k === "Enter" && el.form && el.tagName === "INPUT") el.form.requestSubmit();
        if (proceed && k === "Enter" && el.tagName === "BUTTON") el.click();
        key(el, "keyup", k);
        return true;
      }

      function hover(target) {
        const el = resolve(target);
        const p = center(el);
        for (const t of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"]) mouse(el, t, p);
        return true;
      }

      function select(target, values) {
        const el = resolve(target);
        if (!(el instanceof HTMLSelectElement)) throw new Error("not a <select>");
        const wanted = new Set([].concat(values).map(String));
        let matched = 0;
        for (const option of el.options) {
          const hit = wanted.has(option.value) || wanted.has(option.label) || wanted.has(option.text.trim());
          option.selected = hit;
          if (hit) matched++;
        }
        if (!matched) throw new Error("no option matches " + [...wanted].join(", "));
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return matched;
      }

      function check(target, on) {
        const el = resolve(target);
        const checked = "checked" in el ? el.checked : el.getAttribute("aria-checked") === "true";
        if (checked !== on) click(target);
        return true;
      }

      function scroll(options = {}) {
        if (options.target) {
          resolve(options.target).scrollIntoView({ block: "center", behavior: "instant" });
          return true;
        }
        const amount = options.amount || 600;
        const dx = options.direction === "left" ? -amount : options.direction === "right" ? amount : 0;
        const dy = options.direction === "up" ? -amount : options.direction === "down" || !options.direction ? amount : 0;
        window.scrollBy({ left: dx, top: dy, behavior: "instant" });
        return { x: scrollX, y: scrollY };
      }

      function get(what, target, name) {
        switch (what) {
          case "text": return target ? resolve(target).innerText : document.body.innerText;
          case "html": return target ? resolve(target).outerHTML : document.documentElement.outerHTML;
          case "value": return resolve(target).value;
          case "attr": return resolve(target).getAttribute(name);
          case "count": return document.querySelectorAll(target).length;
          case "box": { const r = resolve(target).getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }
          case "visible": try { return visible(resolve(target)); } catch { return false; }
          case "enabled": return !resolve(target).disabled;
          case "checked": return !!resolve(target).checked;
          case "focused": return document.activeElement === resolve(target);
          default: throw new Error("unknown property " + what);
        }
      }

      async function waitFor(options = {}) {
        const deadline = Date.now() + (options.timeout || 10000);
        const test = () => {
          if (options.selector) {
            const el = document.querySelector(options.selector);
            return options.gone ? !el || !visible(el) : !!el && visible(el);
          }
          if (options.text) {
            const present = document.body.innerText.includes(options.text);
            return options.gone ? !present : present;
          }
          if (options.url) return location.href.includes(options.url);
          if (options.fn) return !!(0, eval)(options.fn);
          return true;
        };
        while (Date.now() < deadline) {
          try { if (test()) return true; } catch {}
          await new Promise(r => setTimeout(r, 100));
        }
        throw new Error("timed out waiting for " + JSON.stringify(options));
      }

      function highlight(target) {
        const el = resolve(target);
        const previous = el.style.outline;
        el.style.outline = "3px solid #ff9f0a";
        setTimeout(() => { el.style.outline = previous; }, 1500);
        center(el);
        return true;
      }

      globalThis.__ghr = { snapshot, resolve, click, fill, type, press, hover, select, check, scroll, get, waitFor, highlight };
    })();
    """#

    /// Page-world script that forwards console output and errors to the app.
    static let consoleHook = #"""
    (() => {
      if (window.__ghrConsole) return;
      window.__ghrConsole = true;
      const post = (level, args) => {
        try {
          const text = args.map(a => {
            if (typeof a === "string") return a;
            try { return JSON.stringify(a); } catch { return String(a); }
          }).join(" ");
          window.webkit.messageHandlers.ghrConsole.postMessage({ level, text });
        } catch {}
      };
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level];
        console[level] = function (...args) { post(level, args); return original.apply(this, args); };
      }
      addEventListener("error", e => {
        // Opaque "Script error." events carry no information (and include
        // our own probes), so skip them.
        if (!e.filename && /^Script error\.?$/.test(e.message)) return;
        post("error", [e.message + " (" + e.filename + ":" + e.lineno + ")"]);
      });
      addEventListener("unhandledrejection", e => post("error", ["Unhandled rejection: " + (e.reason?.stack || e.reason)]));
    })();
    """#
}
