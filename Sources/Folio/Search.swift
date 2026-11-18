import PDFKit
import SwiftUI

struct SearchHit: Identifiable, Hashable {
    /// Index into `BookSearch.hits`.
    let id: Int
    /// Spine index (EPUB) or page index (PDF).
    let section: Int
    /// Which match this is within its section, in document order.
    let occurrence: Int
    /// UTF-16 range in the section's plain text.
    let range: NSRange
    let before: String
    let match: String
    let after: String
}

/// Full-text search over every chapter (EPUB) or page (PDF).
@Observable @MainActor
final class BookSearch {
    nonisolated static let limit = 1000

    var query = "" { didSet { if query != oldValue { schedule() } } }
    /// The query the current `hits` were produced from.
    private(set) var activeQuery = ""
    private(set) var hits: [SearchHit] = []
    private(set) var isSearching = false
    private(set) var isTruncated = false
    var selected: Int?
    var focusToken = 0

    @ObservationIgnored var onUpdate: (() -> Void)?
    @ObservationIgnored private let loadTexts: @Sendable () -> [String]
    @ObservationIgnored private var texts: [String]?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(epub: EPUBBook?, pdf: PDFDocument?) {
        let box = UncheckedBox((epub, pdf))
        loadTexts = {
            if let epub = box.value.0 { return epub.spine.indices.map(epub.text(ofChapter:)) }
            if let pdf = box.value.1 { return (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" } }
            return []
        }
    }

    var isActive: Bool { !hits.isEmpty }

    private func schedule() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let pattern = Self.pattern(for: q) else {
            isSearching = false
            guard !hits.isEmpty || !activeQuery.isEmpty else { return }
            hits = []; activeQuery = ""; selected = nil; isTruncated = false
            onUpdate?()
            return
        }
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let texts = await self.cachedTexts()
            let result = await Task.detached(priority: .userInitiated) { Self.find(pattern, in: texts) }.value
            guard !Task.isCancelled else { return }
            self.hits = result.hits
            self.isTruncated = result.truncated
            self.activeQuery = q
            self.selected = nil
            self.isSearching = false
            self.onUpdate?()
        }
    }

    private func cachedTexts() async -> [String] {
        if let texts { return texts }
        let load = loadTexts
        let loaded = await Task.detached(priority: .userInitiated) { load() }.value
        texts = loaded
        return loaded
    }

    /// Words separated by any run of whitespace, matched literally. Mirrored in `folio.find` (ReaderScripts).
    nonisolated static func pattern(for query: String) -> String? {
        let words = query.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        return words.isEmpty ? nil : words.joined(separator: "\\s+")
    }

    nonisolated static func find(_ pattern: String, in texts: [String]) -> (hits: [SearchHit], truncated: Bool) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return ([], false) }
        var hits: [SearchHit] = []
        for (section, text) in texts.enumerated() {
            let ns = text as NSString
            for (n, m) in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).enumerated() {
                let lo = ns.rangeOfComposedCharacterSequence(at: max(0, m.range.location - 50)).location
                let hiIndex = min(ns.length, NSMaxRange(m.range) + 90)
                let hi = hiIndex < ns.length ? ns.rangeOfComposedCharacterSequence(at: hiIndex).location : ns.length
                var before = Self.flatten(ns.substring(with: NSRange(location: lo, length: m.range.location - lo)))
                var after = Self.flatten(ns.substring(with: NSRange(location: NSMaxRange(m.range), length: hi - NSMaxRange(m.range))))
                if lo > 0, let sp = before.firstIndex(of: " ") { before = "…" + before[sp...] }
                if hi < ns.length, let sp = after.lastIndex(of: " ") { after = after[..<sp] + "…" }
                hits.append(SearchHit(id: hits.count, section: section, occurrence: n, range: m.range,
                                      before: before, match: Self.flatten(ns.substring(with: m.range)), after: after))
                if hits.count >= limit { return (hits, true) }
            }
        }
        return (hits, false)
    }

    private nonisolated static func flatten(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Navigation

extension ReaderModel {
    func beginSearch() {
        sidebarTab = .search
        search.focusToken += 1
    }

    func showHit(_ index: Int) {
        guard search.hits.indices.contains(index) else { return }
        search.selected = index
        let hit = search.hits[index]
        if epub != nil {
            goToChapter(hit.section, anchor: .search(search.activeQuery, hit.occurrence))
        } else {
            pdfView?.showSearchHits(search.hits, current: hit)
        }
    }

    /// Steps through results; with nothing selected yet, starts from the reading position.
    func findNext(_ forward: Bool = true) {
        let hits = search.hits
        guard !hits.isEmpty else { return }
        let index: Int
        if let s = search.selected {
            index = (s + (forward ? 1 : -1) + hits.count) % hits.count
        } else {
            let here = epub != nil ? chapterIndex : pageIndex
            index = forward ? (hits.firstIndex { $0.section >= here } ?? 0)
                            : (hits.lastIndex { $0.section <= here } ?? hits.count - 1)
        }
        showHit(index)
    }

    func searchSectionTitle(_ section: Int) -> String {
        if let epub { return epub.chapterTitle(section) }
        return "p. \(section + 1) · \(pdfSection(for: section).title)"
    }

    /// Marks every match in the loaded chapter without scrolling.
    var searchMarkScript: String {
        search.isActive ? "folio.find(\(ReaderScripts.jsonString(search.activeQuery)), -1, false);" : ""
    }

    func searchDidUpdate() {
        if kind == .epub {
            webView?.evaluateJavaScript(search.isActive ? searchMarkScript : "folio.clearFind()", completionHandler: nil)
        } else {
            pdfView?.showSearchHits(search.hits, current: nil)
        }
    }
}

extension FolioPDFView {
    func showSearchHits(_ hits: [SearchHit], current: SearchHit?) {
        guard let doc = document else { return }
        var selections: [PDFSelection] = []
        var target: PDFSelection?
        for h in hits {
            guard let page = doc.page(at: h.section), let s = page.selection(for: h.range) else { continue }
            if h == current {
                s.color = .findHighlightColor
                target = s
            } else {
                s.color = HighlightColor.yellow.nsColor.withAlphaComponent(0.35)
            }
            selections.append(s)
        }
        highlightedSelections = selections
        if let target { go(to: target) }
    }
}

// MARK: - Sidebar panel

struct SearchPanel: View {
    let reader: ReaderModel
    @Bindable var search: BookSearch
    @FocusState private var focused: Bool

    private var groups: [(section: Int, hits: [SearchHit])] {
        var out: [(section: Int, hits: [SearchHit])] = []
        for h in search.hits {
            if out.last?.section == h.section { out[out.count - 1].hits.append(h) } else { out.append((h.section, [h])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if search.activeQuery.isEmpty {
                if !search.isSearching {
                    placeholder(icon: "magnifyingglass", title: "Search this book",
                                detail: "Find every mention of a word or phrase. Press Return or ⌘G to step through results.")
                }
            } else if search.hits.isEmpty {
                placeholder(icon: "text.magnifyingglass", title: "No results",
                            detail: "Nothing matches “\(search.activeQuery)”.")
            } else {
                results
            }
            Spacer(minLength: 0)
        }
        .onAppear { focused = true }
        .onChange(of: search.focusToken) { focused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search in book", text: $search.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { reader.findNext(!NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { search.query = "" }
            if search.isSearching {
                ProgressView().controlSize(.small)
            } else if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text(search.isTruncated ? "First \(search.hits.count) results" : "\(search.hits.count) result\(search.hits.count == 1 ? "" : "s")")
                Spacer()
                if let s = search.selected { Text("\(s + 1) of \(search.hits.count)").monospacedDigit() }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                List {
                    ForEach(groups, id: \.section) { group in
                        Section(reader.searchSectionTitle(group.section)) {
                            ForEach(group.hits) { hit in
                                Text(snippet(hit))
                                    .font(.system(size: 12.5, design: .serif))
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                    .onTapGesture { reader.showHit(hit.id) }
                                    .listRowBackground(search.selected == hit.id
                                        ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14)).padding(.horizontal, 6)
                                        : nil)
                                    .id(hit.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: search.selected) { _, s in
                    if let s { withAnimation { proxy.scrollTo(s, anchor: .center) } }
                }
            }
        }
    }

    private func snippet(_ hit: SearchHit) -> AttributedString {
        var before = AttributedString(hit.before)
        var match = AttributedString(hit.match)
        var after = AttributedString(hit.after)
        before.foregroundColor = .secondary
        after.foregroundColor = .secondary
        match.font = .system(size: 12.5, weight: .semibold, design: .serif)
        match.backgroundColor = HighlightColor.yellow.color.opacity(0.4)
        return before + match + after
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}
