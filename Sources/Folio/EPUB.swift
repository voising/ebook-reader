import AppKit
import Foundation

enum BookError: LocalizedError {
    case unzipFailed
    case invalidEPUB(String)
    case unreadablePDF
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unzipFailed: "The EPUB archive couldn't be extracted."
        case .invalidEPUB(let why): "This EPUB looks malformed (\(why))."
        case .unreadablePDF: "This PDF couldn't be opened."
        case .unsupported: "Only EPUB and PDF files are supported."
        }
    }
}

final class EPUBBook {
    let root: URL
    let title: String
    let author: String
    let spine: [URL]
    let toc: [TOCEntry]
    let coverURL: URL?

    init(file: URL, bookID: String) throws {
        let fm = FileManager.default
        let dir = AppPaths.caches.appendingPathComponent("EPUB/\(bookID)", isDirectory: true)
        let marker = dir.appendingPathComponent(".folio-extracted")
        if !fm.fileExists(atPath: marker.path) {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", file.path, "-d", dir.path]
            unzip.standardOutput = FileHandle.nullDevice
            unzip.standardError = FileHandle.nullDevice
            try unzip.run()
            unzip.waitUntilExit()
            // unzip exits 1 for mere warnings
            guard unzip.terminationStatus <= 1 else { throw BookError.unzipFailed }
            fm.createFile(atPath: marker.path, contents: Data())
        }
        root = dir.standardizedFileURL

        guard let container = MiniXML.parse(root.appendingPathComponent("META-INF/container.xml")),
              let opfPath = container.first("rootfile")?.attrs["full-path"] else {
            throw BookError.invalidEPUB("missing container.xml")
        }
        let opfURL = root.appendingPathComponent(opfPath).standardizedFileURL
        guard let opf = MiniXML.parse(opfURL) else { throw BookError.invalidEPUB("unreadable package") }
        let opfDir = opfURL.deletingLastPathComponent()

        let metadata = opf.first("metadata")
        title = metadata?.first("title")?.allText.collapsed.nilIfEmpty ?? file.deletingPathExtension().lastPathComponent
        author = metadata?.all("creator").map(\.allText.collapsed).filter { !$0.isEmpty }.joined(separator: ", ") ?? ""

        struct Item { let href: URL; let mediaType: String; let properties: String }
        var manifest: [String: Item] = [:]
        for item in opf.first("manifest")?.all("item") ?? [] {
            guard let id = item.attrs["id"], let href = item.attrs["href"] else { continue }
            manifest[id] = Item(href: Self.resolve(href, in: opfDir).url,
                                mediaType: item.attrs["media-type"] ?? "",
                                properties: item.attrs["properties"] ?? "")
        }

        let spineNode = opf.first("spine")
        let spineURLs = (spineNode?.all("itemref") ?? [])
            .filter { $0.attrs["linear"] != "no" }
            .compactMap { $0.attrs["idref"].flatMap { manifest[$0]?.href } }
        guard !spineURLs.isEmpty else { throw BookError.invalidEPUB("empty spine") }
        spine = spineURLs

        // Cover
        let coverID = metadata?.all("meta").first { $0.attrs["name"] == "cover" }?.attrs["content"]
        coverURL = manifest.values.first { $0.properties.contains("cover-image") }?.href
            ?? coverID.flatMap { manifest[$0]?.href }
            ?? manifest.first { $0.key.lowercased().contains("cover") && $0.value.mediaType.hasPrefix("image") }?.value.href

        // Table of contents: EPUB 3 nav document, then EPUB 2 NCX, then the spine itself.
        var entries: [(String, Int, URL, String?)] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let doc = MiniXML.parse(nav.href) {
            let navs = doc.all("nav")
            let tocNav = navs.first { ($0.attrs["type"] ?? "").contains("toc") } ?? navs.first
            if let ol = tocNav?.first("ol") {
                Self.walkNav(ol, level: 0, base: nav.href.deletingLastPathComponent(), into: &entries)
            }
        }
        if entries.isEmpty,
           let ncxID = spineNode?.attrs["toc"], let ncx = manifest[ncxID], let doc = MiniXML.parse(ncx.href),
           let navMap = doc.first("navMap") {
            Self.walkNCX(navMap, level: 0, base: ncx.href.deletingLastPathComponent(), into: &entries)
        }

        let spinePaths = spineURLs.map(\.path)
        var toc: [TOCEntry] = []
        for (i, entry) in entries.enumerated() {
            let index = spinePaths.firstIndex(of: entry.2.path)
            toc.append(TOCEntry(id: i, title: entry.0, level: entry.1,
                                target: index.map { .chapter($0, fragment: entry.3) }))
        }
        if toc.isEmpty {
            toc = spineURLs.indices.map { TOCEntry(id: $0, title: "Section \($0 + 1)", level: 0, target: .chapter($0, fragment: nil)) }
        }
        self.toc = toc
    }

    func spineIndex(of url: URL) -> Int? {
        let path = url.standardizedFileURL.path
        return spine.firstIndex { $0.path == path }
    }

    func relativeHref(_ index: Int) -> String {
        let full = spine[index].path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : full
    }

    func spineIndex(forHref href: String) -> Int? {
        spine.indices.first { relativeHref($0) == href }
    }

    func chapterTitle(_ index: Int) -> String {
        var best: TOCEntry?
        for entry in toc {
            guard case .chapter(let i, _)? = entry.target else { continue }
            if i == index { return entry.title }
            if i < index { best = entry }
        }
        return best?.title ?? "Section \(index + 1)"
    }

    func text(ofChapter index: Int) -> String {
        guard spine.indices.contains(index),
              let data = try? Data(contentsOf: spine[index]),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return "" }
        return HTMLText.plain(html)
    }

    // MARK: - TOC parsing

    private static func resolve(_ href: String, in dir: URL) -> (url: URL, fragment: String?) {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        let fragment = parts.count > 1 ? String(parts[1]) : nil
        return (dir.appendingPathComponent(path).standardizedFileURL, fragment)
    }

    private static func walkNav(_ ol: XNode, level: Int, base: URL, into out: inout [(String, Int, URL, String?)]) {
        for li in ol.children where li.name == "li" {
            if let a = li.children.first(where: { $0.name == "a" || $0.name == "span" }) {
                let title = a.allText.collapsed
                if let href = a.attrs["href"], !title.isEmpty {
                    let r = resolve(href, in: base)
                    out.append((title, level, r.url, r.fragment))
                }
            }
            for sub in li.children where sub.name == "ol" {
                walkNav(sub, level: level + 1, base: base, into: &out)
            }
        }
    }

    private static func walkNCX(_ node: XNode, level: Int, base: URL, into out: inout [(String, Int, URL, String?)]) {
        for point in node.children where point.name == "navPoint" {
            let title = point.first("navLabel")?.allText.collapsed ?? ""
            if let src = point.children.first(where: { $0.name == "content" })?.attrs["src"], !title.isEmpty {
                let r = resolve(src, in: base)
                out.append((title, level, r.url, r.fragment))
            }
            walkNCX(point, level: level + 1, base: base, into: &out)
        }
    }
}

// MARK: - Minimal XML tree

final class XNode {
    let name: String
    let attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func all(_ name: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.all(name))
        }
        return out
    }

    func first(_ name: String) -> XNode? {
        for c in children {
            if c.name == name { return c }
            if let f = c.first(name) { return f }
        }
        return nil
    }

    var allText: String { text + children.map(\.allText).joined() }
}

final class MiniXML: NSObject, XMLParserDelegate {
    private let root = XNode(name: "#root", attrs: [:])
    private var stack: [XNode] = []

    static func parse(_ url: URL) -> XNode? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = XMLParser(data: data)
        let builder = MiniXML()
        builder.stack = [builder.root]
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        parser.parse() // partial trees are still useful on error
        return builder.root.children.isEmpty ? nil : builder.root
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict { attrs[Self.local(k)] = v }
        let node = XNode(name: Self.local(elementName), attrs: attrs)
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Text is attached to the innermost element; good enough for titles/labels.
        stack.last?.children.append({ let t = XNode(name: "#text", attrs: [:]); t.text = string; return t }())
    }
}

// MARK: - HTML → plain text (for sending chapters to Claude)

enum HTMLText {
    static func plain(_ html: String) -> String {
        var s = html
        let removals = ["(?is)<head\\b.*?</head>", "(?is)<script\\b.*?</script>", "(?is)<style\\b.*?</style>", "(?s)<!--.*?-->"]
        for r in removals { s = s.replacingOccurrences(of: r, with: "", options: .regularExpression) }
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|blockquote|tr|section|figure)>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        let lines = s.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ input: String) -> String {
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                     "&rdquo;": "”", "&ldquo;": "“"]
        var s = input
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = ns.substring(with: m.range(at: 2))
                if let v = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(v) {
                    out.append(Character(scalar))
                }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        for (k, v) in named { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}

extension String {
    var collapsed: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}
