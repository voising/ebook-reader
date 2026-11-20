import CryptoKit
import SwiftUI
import WebKit

/// Turns a web article into a small EPUB, so it can be read, highlighted and studied like any book.
/// The page is loaded in a hidden web view, its main text is picked out, and only plain structure
/// (paragraphs, headings, lists, quotes, links, images) is carried over.
enum Articles {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What the page reader hands back.
    struct Page: Decodable {
        var title: String
        var byline: String?
        var site: String?
        var lang: String?
        var published: String?
        var image: String?
        var url: String?
        var words: Int
        var blocks: [Block]
    }

    struct Block: Decodable {
        /// p, h2, h3, quote, li, oli, pre, cap, img, hr
        var t: String
        var runs: [Run]?
        var src: String?
        var alt: String?
    }

    struct Run: Decodable {
        var s: String
        var b: Bool?
        var i: Bool?
        var c: Bool?
        var href: String?
    }

    static let directory: URL = {
        let dir = AppPaths.support.appendingPathComponent("Articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Accepts "example.com/post" as well as a full link; only http and https.
    static func link(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    static func fileURL(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).epub")
    }

    @MainActor
    static func importArticle(_ input: String, status: @escaping (String) -> Void) async throws -> URL {
        guard let url = link(from: input) else { throw ImportError(message: "That doesn't look like a web link.") }
        let out = fileURL(for: url)
        // The same link always opens the same file: a rebuilt one would count as a different book.
        if FileManager.default.fileExists(atPath: out.path) { return out }

        status("Loading the page…")
        let page = try await read(url)
        guard page.words >= 120 else {
            throw ImportError(message: "Couldn't find an article on that page. It may need a login, or be mostly video or images.")
        }
        status("Building the article…")
        var cover: (data: Data, type: String)?
        if let image = page.image.flatMap(URL.init(string:)) {
            var request = URLRequest(url: image)
            request.timeoutInterval = 15
            if let (data, response) = try? await URLSession.shared.data(for: request), data.count < 6_000_000,
               let type = response.mimeType, ["image/jpeg", "image/png", "image/webp"].contains(type) {
                cover = (data, type)
            }
        }
        try epub(page, source: url, cover: cover).write(to: out, options: .atomic)
        return out
    }

    /// Loads the page and picks out its article.
    @MainActor
    static func read(_ url: URL) async throws -> Page { try await PageReader().read(url) }

    // MARK: Building the book

    static func epub(_ page: Page, source: URL, cover: (data: Data, type: String)?) -> Data {
        let lang = escape(String((page.lang ?? "en").prefix(2)))
        let title = page.title.collapsed.nilIfEmpty ?? source.host ?? "Article"
        let site = page.site?.collapsed.nilIfEmpty ?? source.host ?? ""
        let byline = page.byline?.collapsed.nilIfEmpty
        var credits = [byline, site.nilIfEmpty, displayDate(page.published)].compactMap { $0 }.map(escape)
        credits.append("<a href=\"\(escape(source.absoluteString))\">Original article</a>")

        var body = "<h1>\(escape(title))</h1>\n<p class=\"src\">\(credits.joined(separator: " · "))</p>\n"
        var sections: [(id: String, title: String)] = []
        var list: String?
        func closeList() { if let open = list { body += "</\(open)>\n"; list = nil } }
        for block in page.blocks {
            let inline = (block.runs ?? []).map(html).joined()
            let plain = (block.runs ?? []).map(\.s).joined().collapsed
            if block.t == "li" || block.t == "oli" {
                let tag = block.t == "oli" ? "ol" : "ul"
                if list != tag { closeList(); body += "<\(tag)>\n"; list = tag }
                body += "<li>\(inline)</li>\n"
                continue
            }
            closeList()
            switch block.t {
            case "h2":
                let id = "s\(sections.count + 1)"
                sections.append((id, plain))
                body += "<h2 id=\"\(id)\">\(inline)</h2>\n"
            case "h3": body += "<h3>\(inline)</h3>\n"
            case "quote": body += "<blockquote><p>\(inline)</p></blockquote>\n"
            case "pre": body += "<pre>\(escape((block.runs ?? []).map(\.s).joined()))</pre>\n"
            case "cap": body += "<p class=\"cap\">\(inline)</p>\n"
            case "hr": body += "<hr/>\n"
            case "img":
                guard let src = block.src, src.hasPrefix("http://") || src.hasPrefix("https://") else { continue }
                body += "<p class=\"fig\"><img src=\"\(escape(src))\" alt=\"\(escape(block.alt ?? ""))\"/></p>\n"
            default:
                if !plain.isEmpty { body += "<p>\(inline)</p>\n" }
            }
        }
        closeList()

        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)" lang="\(lang)">
        <head><meta charset="utf-8"/><title>\(escape(title))</title>
        <style>.src { font-size: 0.8em; opacity: 0.65; } .cap { font-size: 0.85em; opacity: 0.7; text-align: center; } .fig { text-align: center; } img { max-width: 100%; height: auto; }</style>
        </head>
        <body>
        \(body)</body></html>
        """
        let subsections = sections.isEmpty ? "" : "<ol>\n" + sections.map {
            "<li><a href=\"article.xhtml#\($0.id)\">\(escape($0.title))</a></li>"
        }.joined(separator: "\n") + "\n</ol>"
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>
        <li><a href="article.xhtml">\(escape(title))</a>\(subsections)</li>
        </ol></nav></body></html>
        """
        let coverName = cover.map { "cover." + ($0.type == "image/png" ? "png" : $0.type == "image/webp" ? "webp" : "jpg") }
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">web:\(escape(source.absoluteString))</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:creator>\(escape(byline ?? site))</dc:creator>
            <dc:language>\(lang)</dc:language>
            <dc:source>\(escape(source.absoluteString))</dc:source>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="article" href="article.xhtml" media-type="application/xhtml+xml"/>
            \(coverName.map { "<item id=\"cover\" href=\"\($0)\" media-type=\"\(cover!.type)\" properties=\"cover-image\"/>" } ?? "")
          </manifest>
          <spine><itemref idref="article"/></spine>
        </package>
        """
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        var files: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
            ("OEBPS/article.xhtml", Data(chapter.utf8)),
        ]
        if let cover, let coverName { files.append(("OEBPS/" + coverName, cover.data)) }
        return Zip.archive(files)
    }

    private static func html(_ run: Run) -> String {
        var out = escape(run.s)
        if run.c == true { out = "<code>\(out)</code>" }
        if run.i == true { out = "<em>\(out)</em>" }
        if run.b == true { out = "<strong>\(out)</strong>" }
        if let href = run.href, href.hasPrefix("http://") || href.hasPrefix("https://") {
            out = "<a href=\"\(escape(href))\">\(out)</a>"
        }
        return out
    }

    /// Escapes for XML and drops the control characters XML doesn't allow.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = scalar.value
                if v >= 0x20 || v == 0x9 || v == 0xA || v == 0xD, v != 0xFFFE, v != 0xFFFF { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private static func displayDate(_ iso: String?) -> String? {
        guard let iso, !iso.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: iso) { return date.formatted(date: .abbreviated, time: .omitted) }
        }
        return nil
    }
}

// MARK: - Reading the page

/// Loads a page in a web view nobody sees and asks it for its main text. The page's own scripts run
/// (many sites need them to show anything), but nothing from the page reaches Folio except text.
@MainActor
private final class PageReader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?
    private var failure: Error?

    func read(_ url: URL) async throws -> Articles.Page {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1400), configuration: config)
        webView.navigationDelegate = self
        self.webView = webView
        defer { webView.stopLoading(); self.webView = nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
        // Some pages never finish loading (trackers, video): after a while, read what is there.
        let giveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(18))
            self?.finish()
        }
        await withCheckedContinuation { loaded = $0 }
        giveUp.cancel()
        try? await Task.sleep(for: .milliseconds(1200))

        let raw = try? await webView.evaluateJavaScript(Self.script, in: nil, contentWorld: .defaultClient) as? String
        guard let raw, let page = try? JSONDecoder().decode(Articles.Page.self, from: Data(raw.utf8)) else {
            throw Articles.ImportError(message: failure.map { "Couldn't load that page: \($0.localizedDescription)" }
                                       ?? "Couldn't read that page.")
        }
        if page.words < 120, let failure {
            throw Articles.ImportError(message: "Couldn't load that page: \(failure.localizedDescription)")
        }
        return page
    }

    private func finish() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error
        finish()
    }

    /// Finds the element holding most of the long paragraphs and walks it into a flat list of blocks.
    private static let script = #"""
    (function () {
      const meta = (s) => { const e = document.querySelector(s); return e ? (e.getAttribute('content') || '').trim() : ''; };
      const clean = (t) => (t || '').replace(/\s+/g, ' ').trim();
      const BAD = /(^|[\s_-])(comments?|share|sharing|social|promo|related|sidebar|newsletter|subscribe|cookie|banner|advert|ads?|footer|masthead|breadcrumbs?|popup|modal|paywall|recirc|outbrain|taboola|toolbar|nav|menu|tags?)([\s_-]|$)/i;
      const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'NAV', 'ASIDE', 'FOOTER', 'FORM', 'BUTTON', 'IFRAME', 'SVG', 'INPUT', 'SELECT', 'TEXTAREA', 'TEMPLATE', 'DIALOG', 'VIDEO', 'AUDIO', 'CANVAS', 'OBJECT', 'EMBED']);
      const BLOCK = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'UL', 'OL', 'LI', 'PRE', 'FIGURE', 'IMG', 'PICTURE', 'TABLE', 'DIV', 'SECTION', 'ARTICLE', 'MAIN', 'HEADER', 'DL', 'DT', 'DD', 'FIGCAPTION', 'HR', 'DETAILS', 'SUMMARY', 'CENTER']);
      const tagOf = (el) => el.tagName.toUpperCase();

      const scores = new Map();
      document.querySelectorAll('p').forEach((p) => {
        const n = clean(p.innerText).length;
        if (n < 80) return;
        let el = p.parentElement, w = 1;
        for (let d = 0; el && d < 3; d++, el = el.parentElement, w /= 2) scores.set(el, (scores.get(el) || 0) + n * w);
      });
      let best = null, top = 0;
      scores.forEach((v, el) => { if (v > top) { top = v; best = el; } });
      if (!best) best = document.querySelector('article, main, [role=main]') || document.body;
      if (!best) return JSON.stringify({ title: document.title || '', words: 0, blocks: [] });
      const article = best.closest('article');
      if (article && clean(article.innerText).length < clean(best.innerText).length * 2.5) best = article;

      const h1 = document.querySelector('h1');
      // Shared titles often carry the site's name ("Post - Site"); the page's own heading is cleaner when it matches.
      const shared = clean(meta('meta[property="og:title"]') || document.title), heading = clean(h1 ? h1.innerText : '');
      const title = heading && (!shared || shared.includes(heading)) ? heading : (shared || heading);
      const abs = (u) => { try { const x = new URL(u, location.href); return /^https?:$/.test(x.protocol) ? x.href : null; } catch (e) { return null; } };
      const hidden = (el) => { const s = getComputedStyle(el); return s.display === 'none' || s.visibility === 'hidden'; };
      function unwanted(el) {
        if (SKIP.has(tagOf(el)) || hidden(el)) return true;
        const sig = (typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
        return BAD.test(sig) && clean(el.innerText).length < top * 0.5;
      }
      function runs(el) {
        const out = [];
        (function walk(n, st) {
          for (const c of n.childNodes) {
            if (c.nodeType === 3) {
              const s = c.data.replace(/\s+/g, ' ');
              if (s) out.push(Object.assign({ s }, st));
            } else if (c.nodeType === 1) {
              const tag = tagOf(c);
              if (tag === 'BR') { out.push({ s: ' ' }); continue; }
              if (SKIP.has(tag) || tag === 'IMG' || tag === 'PICTURE' || tag === 'FIGURE' || hidden(c)) continue;
              if (tag === 'SUP' && c.querySelector('a')) continue; // footnote markers like [1]
              const next = Object.assign({}, st);
              if (tag === 'B' || tag === 'STRONG') next.b = true;
              if (tag === 'I' || tag === 'EM' || tag === 'CITE') next.i = true;
              if (tag === 'CODE' || tag === 'KBD') next.c = true;
              if (tag === 'A') { const h = abs(c.getAttribute('href') || ''); if (h) next.href = h; }
              walk(c, next);
            }
          }
        })(el, {});
        while (out.length && !out[0].s.trim()) out.shift();
        while (out.length && !out[out.length - 1].s.trim()) out.pop();
        return out;
      }
      const text = (rs) => rs.map((r) => r.s).join('');
      const blocks = [];
      function push(t, el, min) {
        const rs = runs(el);
        if (clean(text(rs)).length >= (min || 1)) blocks.push({ t, runs: rs });
      }
      function image(el) {
        const src = abs(el.currentSrc || el.getAttribute('src') || el.getAttribute('data-src') || '');
        if (!src) return;
        if ((el.naturalWidth && el.naturalWidth < 200) || (el.width && el.width < 120)) return;
        blocks.push({ t: 'img', src, alt: clean(el.getAttribute('alt')) });
      }
      function hasBlockChild(el) { for (const c of el.children) if (BLOCK.has(tagOf(c))) return true; return false; }
      function walk(el) {
        for (const c of el.children) {
          if (blocks.length > 4000 || unwanted(c)) continue;
          const tag = tagOf(c);
          if (tag === 'P') push('p', c);
          else if (tag === 'H1') { if (clean(c.innerText) !== title) push('h2', c); }
          else if (tag === 'H2') push('h2', c);
          else if (/^H[3-6]$/.test(tag)) push('h3', c);
          else if (tag === 'BLOCKQUOTE') push('quote', c);
          else if (tag === 'UL' || tag === 'OL') {
            for (const li of c.children) if (tagOf(li) === 'LI' && !unwanted(li)) push(tag === 'OL' ? 'oli' : 'li', li);
          }
          else if (tag === 'PRE') { const s = c.innerText.replace(/\s+$/, ''); if (s) blocks.push({ t: 'pre', runs: [{ s }] }); }
          else if (tag === 'IMG') image(c);
          else if (tag === 'PICTURE') { const i = c.querySelector('img'); if (i) image(i); }
          else if (tag === 'FIGURE') {
            const i = c.querySelector('img'), cap = c.querySelector('figcaption');
            if (i) image(i);
            if (cap) push('cap', cap);
            if (!i && !cap) walk(c);
          }
          else if (tag === 'TABLE') {
            for (const row of c.querySelectorAll('tr')) {
              const cells = Array.from(row.children).map((x) => clean(x.innerText)).filter(Boolean);
              if (cells.length) blocks.push({ t: 'p', runs: [{ s: cells.join(' — ') }] });
            }
          }
          else if (tag === 'HR') blocks.push({ t: 'hr' });
          else if (hasBlockChild(c)) walk(c);
          else push('p', c, 25);
        }
      }
      walk(best);

      const words = blocks.reduce((n, b) => n + (b.runs ? clean(text(b.runs)).split(' ').filter(Boolean).length : 0), 0);
      const by = document.querySelector('[rel="author"], [itemprop="author"], .byline, .author');
      let byline = clean(meta('meta[name="author"]') || meta('meta[property="article:author"]') || (by ? by.innerText : ''));
      if (/^https?:/.test(byline) || byline.length > 80) byline = '';
      return JSON.stringify({
        title, byline,
        site: clean(meta('meta[property="og:site_name"]')) || location.hostname.replace(/^www\./, ''),
        lang: (document.documentElement.lang || 'en').slice(0, 2),
        published: meta('meta[property="article:published_time"]') || meta('meta[name="date"]'),
        image: abs(meta('meta[property="og:image"]') || '') || '',
        url: location.href, words, blocks,
      });
    })()
    """#
}
