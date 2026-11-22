import PDFKit
import SwiftUI
import WebKit

struct LoadedBook {
    let url: URL
    let bookID: String
    let kind: BookKind
    let title: String
    let author: String
    let epub: EPUBBook?
    let pdf: PDFDocument?
    let toc: [TOCEntry]
}

enum BookLoader {
    static func load(url: URL) throws -> LoadedBook {
        let ext = url.pathExtension.lowercased()
        let id = try BookIdentity.id(for: url)
        let coverURL = AppPaths.cover(for: id)
        let needsCover = !FileManager.default.fileExists(atPath: coverURL.path)

        switch ext {
        case "epub":
            let book = try EPUBBook(file: url, bookID: id)
            if needsCover, let src = book.coverURL, let image = PlatformImage.load(src) {
                CoverRenderer.savePNG(image, to: coverURL)
            }
            return LoadedBook(url: url, bookID: id, kind: .epub, title: book.title, author: book.author,
                              epub: book, pdf: nil, toc: book.toc)
        case "pdf":
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw BookError.unreadablePDF }
            if needsCover, let page = doc.page(at: 0) {
                CoverRenderer.savePNG(page.thumbnail(of: CGSize(width: 400, height: 560), for: .cropBox), to: coverURL)
            }
            let attrs = doc.documentAttributes ?? [:]
            let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.collapsed.nilIfEmpty
                ?? url.deletingPathExtension().lastPathComponent
            let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.collapsed ?? ""
            return LoadedBook(url: url, bookID: id, kind: .pdf, title: title, author: author,
                              epub: nil, pdf: doc, toc: pdfTOC(doc))
        default:
            throw BookError.unsupported
        }
    }

    private static func pdfTOC(_ doc: PDFDocument) -> [TOCEntry] {
        var out: [TOCEntry] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let page = child.destination?.page.map { doc.index(for: $0) }
                out.append(TOCEntry(id: out.count, title: (child.label ?? "Untitled").collapsed, level: level,
                                    target: page.map { .page($0) }))
                walk(child, level: level + 1)
            }
        }
        if let root = doc.outlineRoot { walk(root, level: 0) }
        return out
    }
}

enum ReaderAnchor: Equatable {
    case top
    case fraction(Double)
    case fragment(String)
    case highlight(String)
    case search(String, Int)
}

@Observable @MainActor
final class ReaderModel {
    let url: URL
    let bookID: String
    let kind: BookKind
    let title: String
    let author: String
    let epub: EPUBBook?
    let pdf: PDFDocument?
    let toc: [TOCEntry]
    let chat: ChatModel
    let search: BookSearch
    let study: StudyModel
    let listen = ListenModel()
    let catchUp = CatchUpModel()
    var showCatchUp = false
    /// Frozen before scroll restoration or cloud updates can replace the previous session.
    let previousRecord: BookRecord
    /// Set for transcripts imported from YouTube.
    let videoID: String?

    private(set) var record: BookRecord
    var chapterIndex = 0
    var chapterFraction = 0.0
    var pageIndex = 0
    var pendingAnchor: ReaderAnchor?
    var anchorToken = 0
    var showChat = Platform.hasClaude
    var sidebarTab: SidebarTab = .contents
    /// Bumped to bring the sidebar on screen when it is collapsed.
    var sidebarToken = 0
    var showVideo = true
    var videoSeek = VideoSeek(time: 0, token: 0)
    /// True when the synced record exists but couldn't be read; nothing is written until it can be.
    private(set) var saveBlocked = false
    /// The word whose definition card is showing.
    var lookup: WordLookup?

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored weak var pdfView: FolioPDFView?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReadPassage: ReadPassage?
    @ObservationIgnored var onProgress: ((String, Double) -> Void)?
    /// Highlight ids as of the last load or save, used to tell what another device added or removed since.
    @ObservationIgnored private var syncedHighlightIDs: Set<String> = []

    enum SidebarTab: String, CaseIterable { case contents = "Contents", highlights = "Highlights", notes = "Notes", search = "Search" }

    init(_ book: LoadedBook) {
        url = book.url
        bookID = book.bookID
        kind = book.kind
        title = book.title
        author = book.author
        epub = book.epub
        pdf = book.pdf
        toc = book.toc
        chat = ChatModel(scope: .book(title: book.title, author: book.author))
        search = BookSearch(epub: book.epub, pdf: book.pdf)
        study = StudyModel(bookID: book.bookID, title: book.title, author: book.author)
        videoID = YouTube.videoID(forImported: book.epub)
        let loadedRecord: BookRecord
        switch CloudStore.loadResult(book.bookID) {
        case .value(let saved):
            loadedRecord = saved
        case .missing:
            loadedRecord = BookRecord(bookID: book.bookID, title: book.title, author: book.author, kind: book.kind)
        case .unreadable:
            loadedRecord = BookRecord(bookID: book.bookID, title: book.title, author: book.author, kind: book.kind)
            saveBlocked = true
        }

        record = loadedRecord
        previousRecord = loadedRecord
        syncedHighlightIDs = Set(record.highlights.map(\.id))
        if let pos = record.position {
            if let epub, let c = pos.chapter, epub.spine.indices.contains(c) {
                chapterIndex = c
                chapterFraction = pos.fraction ?? 0
                pendingAnchor = .fraction(chapterFraction)
            }
            if let pdf, let p = pos.page, p < pdf.pageCount { pageIndex = p }
        }
        chat.contextProvider = { [weak self] in self?.currentContext() }
        chat.restore(study.data.chat)
        chat.onPersist = { [weak self] stored in self?.study.saveChat(stored) }
        study.reader = self
        listen.reader = self
        search.onUpdate = { [weak self] in self?.searchDidUpdate() }
    }

    // MARK: - Derived

    var chapterCount: Int { epub?.spine.count ?? pdf?.pageCount ?? 0 }

    var currentChapterTitle: String {
        if let epub { return epub.chapterTitle(chapterIndex) }
        return pdfSection().title
    }

    var progress: Double {
        if let epub { return min(1, (Double(chapterIndex) + chapterFraction) / Double(max(epub.spine.count, 1))) }
        if let pdf { return Double(pageIndex + 1) / Double(max(pdf.pageCount, 1)) }
        return 0
    }

    var positionLabel: String {
        if let epub { return "Chapter \(chapterIndex + 1) of \(epub.spine.count)" }
        return "Page \(pageIndex + 1) of \(pdf?.pageCount ?? 0)"
    }

    var highlights: [Highlight] { record.highlights }

    var sortedHighlights: [Highlight] {
        record.highlights.sorted { a, b in
            if let epub {
                let ia = a.chapterHref.flatMap(epub.spineIndex(forHref:)) ?? .max
                let ib = b.chapterHref.flatMap(epub.spineIndex(forHref:)) ?? .max
                return ia != ib ? ia < ib : (a.start ?? 0) < (b.start ?? 0)
            }
            let pa = a.page ?? .max, pb = b.page ?? .max
            return pa != pb ? pa < pb : (a.rects?.first?.y ?? 0) > (b.rects?.first?.y ?? 0)
        }
    }

    func isCurrent(_ entry: TOCEntry) -> Bool {
        switch entry.target {
        case .chapter(let i, _)?: return i == chapterIndex
        case .page(let p)?:
            let next = toc.first { e in if case .page(let q)? = e.target { return q > p } ; return false }
            if case .page(let q)? = next?.target { return pageIndex >= p && pageIndex < q }
            return pageIndex >= p
        default: return false
        }
    }

    // MARK: - Navigation

    func go(to entry: TOCEntry) {
        switch entry.target {
        case .chapter(let i, let fragment)?:
            goToChapter(i, anchor: fragment.map { .fragment($0) } ?? .top)
        case .page(let p)?:
            goToPage(p)
        case nil: break
        }
    }

    func goToChapter(_ index: Int, anchor: ReaderAnchor = .top) {
        guard let epub, epub.spine.indices.contains(index) else { return }
        lookup = nil
        // The audio belongs to the chapter being left.
        if index != chapterIndex { listen.stop() }
        pendingAnchor = anchor
        anchorToken += 1
        if index != chapterIndex { chapterFraction = 0 }
        chapterIndex = index
        savePosition()
    }

    func goToPage(_ index: Int) {
        guard let pdf, let page = pdf.page(at: index) else { return }
        pdfView?.go(to: page)
    }

    #if os(iOS)
    /// Head-nod page turn. In landscape it scrolls like a double tap. In portrait a PDF goes to its next
    /// page; a book jumps one screen (no scrolling, a quick cross-fade instead), and from the end of a
    /// chapter on to the next one.
    func turnPageOnNod() {
        let view: UIView? = pdf != nil ? pdfView : webView
        guard let view, let scene = view.window?.windowScene else { return }
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            (pdf != nil ? view.firstScrollView() : webView?.scrollView)?.pageDown()
            return
        }
        if let pdfView, pdf != nil {
            // Keep the trimmed-margin zoom lined up on the next page's text.
            let fitted = pdfView.isFittedToText
            pdfView.goToNextPage(nil)
            if fitted, let page = pdfView.currentPage { pdfView.fitText(of: page) }
            return
        }
        guard let webView else { return }
        let scroll = webView.scrollView
        let inset = scroll.adjustedContentInset
        let visible = scroll.bounds.height - inset.top - inset.bottom
        let maxY = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        guard scroll.contentOffset.y < maxY - 1 else {
            if canGoNext { next() }
            return
        }
        // Keep one line of overlap so the eye can find its place.
        let target = min(maxY, scroll.contentOffset.y + visible - 24)
        UIView.transition(with: webView, duration: 0.18, options: .transitionCrossDissolve) {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        }
    }
    #endif

    func next() {
        if epub != nil { goToChapter(chapterIndex + 1) } else { pdfView?.goToNextPage(nil) }
    }

    func previous() {
        if epub != nil { goToChapter(chapterIndex - 1) } else { pdfView?.goToPreviousPage(nil) }
    }

    var canGoNext: Bool { epub != nil ? chapterIndex < chapterCount - 1 : pageIndex < chapterCount - 1 }
    var canGoPrevious: Bool { epub != nil ? chapterIndex > 0 : pageIndex > 0 }

    func reveal(_ h: Highlight) {
        if let epub, let href = h.chapterHref, let idx = epub.spineIndex(forHref: href) {
            goToChapter(idx, anchor: .highlight(h.id))
        } else if let pdf, let r = h.rects?.first, let page = pdf.page(at: r.page) {
            pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: r.x, y: r.y + r.h + 80)))
            pdfView?.flash(h.id)
        }
    }

    func updateFraction(_ f: Double) {
        chapterFraction = f
        savePosition()
    }

    func updatePage(_ p: Int) {
        guard p != pageIndex else { return }
        pageIndex = p
        savePosition()
    }

    // MARK: - Highlights

    func addEPUBHighlight(start: Int, end: Int, text: String, color: HighlightColor, focus: Bool = false) {
        guard let epub else { return }
        let h = Highlight(text: text, color: color, chapterHref: epub.relativeHref(chapterIndex),
                          chapterTitle: epub.chapterTitle(chapterIndex), start: start, end: end)
        record.highlights.append(h)
        js("folio.apply(\(Self.json(h)))" + (focus ? "; folio.focus(\(ReaderScripts.jsonString(h.id)))" : ""))
        persist()
    }

    @discardableResult
    func addPDFHighlight(text: String, rects: [PageRect], color: HighlightColor) -> String {
        let h = Highlight(text: text, color: color, chapterTitle: pdfSection(for: rects.first?.page).title, rects: rects)
        record.highlights.append(h)
        pdfView?.addAnnotations(for: h)
        persist()
        return h.id
    }

    func recolor(_ id: String, to color: HighlightColor) {
        guard let i = record.highlights.firstIndex(where: { $0.id == id }) else { return }
        record.highlights[i].color = color
        js("folio.recolor(\(ReaderScripts.jsonString(id)), '\(color.rawValue)')")
        pdfView?.removeAnnotations(for: id)
        if kind == .pdf { pdfView?.addAnnotations(for: record.highlights[i]) }
        persist()
    }

    func removeHighlight(_ id: String) {
        guard let removed = record.highlights.first(where: { $0.id == id }) else { return }
        record.highlights.removeAll { $0.id == id }
        js("folio.remove(\(ReaderScripts.jsonString(id)))")
        pdfView?.removeAnnotations(for: id)
        persist()
        AppModel.shared.offerUndo("Highlight deleted") { [weak self] in self?.restoreHighlight(removed) }
    }

    private func restoreHighlight(_ h: Highlight) {
        guard !record.highlights.contains(where: { $0.id == h.id }) else { return }
        record.highlights.append(h)
        if kind == .pdf {
            pdfView?.addAnnotations(for: h)
        } else if let epub, h.chapterHref == epub.relativeHref(chapterIndex) {
            // Other chapters draw their highlights when they load.
            js("folio.apply(\(Self.json(h)))")
        }
        persist()
    }

    /// Opens the sidebar on a tab, revealing it if it is collapsed.
    func showSidebar(_ tab: SidebarTab) {
        sidebarTab = tab
        sidebarToken += 1
    }

    // MARK: - Word list

    /// Saves a double-clicked word to the library-wide list. Returns the cleaned word, or nil if nothing was saved.
    @discardableResult
    func saveWord(_ raw: String, context: String?, anchor: CGRect? = nil) -> String? {
        let source = [title, currentChapterTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        let saved = AppModel.shared.words.add(raw, context: context, bookID: bookID, source: source)
        if let saved, let anchor { lookup = WordLookup(word: saved, anchor: anchor) }
        return saved
    }

    func undoSaveWord(_ raw: String) {
        AppModel.shared.words.undoAdd(raw)
        lookup = nil
    }

    func highlightSelection(_ color: HighlightColor = .yellow) {
        if kind == .epub { js("folio.highlightSelection('\(color.rawValue)')") } else { pdfView?.highlightSelection(color) }
    }

    func askAboutSelection() {
        if kind == .epub { js("folio.askSelection()") } else { pdfView?.askAboutSelection() }
    }

    func ask(about passage: String) {
        chat.quote = passage
        showChat = true
        chat.focusToken += 1
    }

    // MARK: - Book note

    var note: String {
        get { record.note ?? "" }
        set {
            guard newValue != record.note ?? "" else { return }
            record.note = newValue
            record.noteUpdatedAt = Date()
            persist()
        }
    }

    var noteUpdatedAt: Date? { record.noteUpdatedAt }

    func appendToNote(_ h: Highlight) {
        let quote = "> " + h.text.replacingOccurrences(of: "\n", with: "\n> ")
        let source = h.chapterTitle ?? h.page.map { "Page \($0 + 1)" }
        let entry = quote + (source.map { "\n— \($0)" } ?? "")
        note = note.isEmpty ? entry + "\n\n" : note.trimmingCharacters(in: .newlines) + "\n\n" + entry + "\n\n"
        showSidebar(.notes)
    }

    func chapterHighlights(_ index: Int) -> [Highlight] {
        guard let epub else { return [] }
        let href = epub.relativeHref(index)
        return record.highlights.filter { $0.chapterHref == href }
    }

    func markdownExport() -> String {
        var out = "# \(title)\n"
        if !author.isEmpty { out += "*\(author)*\n" }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\n## Notes\n\n\(note.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        var lastSection: String?
        for h in sortedHighlights {
            let section = h.chapterTitle ?? h.page.map { "Page \($0 + 1)" } ?? ""
            if section != lastSection { out += "\n## \(section)\n"; lastSection = section }
            out += "\n> \(h.text.replacingOccurrences(of: "\n", with: "\n> "))\n"
            if let note = h.note, !note.isEmpty { out += "\n\(note)\n" }
        }
        return out
    }

    /// Picks up highlights edited on another Mac.
    func reloadFromCloud() {
        study.reloadFromCloud()
        if saveBlocked {
            // The record became readable (e.g. iCloud finished downloading): adopt it, keeping anything added meanwhile.
            switch CloudStore.loadResult(bookID) {
            case .value(var disk):
                disk.mergeReadingHistory(record)
                let known = Set(disk.highlights.map(\.id))
                disk.highlights += record.highlights.filter { !known.contains($0.id) }
                disk.position = record.position ?? disk.position
                disk.progress = max(disk.progress, record.progress)
                record = disk
                saveBlocked = false
                persist()
            case .missing:
                saveBlocked = false
                persist()
                return
            case .unreadable:
                return
            }
        } else {
            guard var disk = CloudStore.load(bookID), disk.updatedAt > record.updatedAt.addingTimeInterval(1) else { return }
            disk.mergeReadingHistory(record)
            record = disk
        }
        syncedHighlightIDs = Set(record.highlights.map(\.id))
        refreshHighlights()
    }

    /// Redraws the highlights after they changed underneath the page.
    private func refreshHighlights() {
        if kind == .pdf {
            pdfView?.reinstallAnnotations(record.highlights)
        } else {
            // Reloading the page drops the marks Listen follows the text with.
            listen.stop()
            anchorToken += 1
            pendingAnchor = .fraction(chapterFraction)
            webView?.reload()
        }
    }

    /// Saves the record without undoing what another device saved since this one last looked: highlights
    /// added there are taken in, ones removed there are dropped, and everything made here is kept.
    private func writeRecord() {
        guard !saveBlocked else { return }
        if case .value(let disk) = CloudStore.loadResult(bookID) {
            record.mergeReadingHistory(disk)
            let onDisk = Set(disk.highlights.map(\.id)), mine = Set(record.highlights.map(\.id))
            let removedElsewhere = syncedHighlightIDs.subtracting(onDisk).intersection(mine)
            let addedElsewhere = disk.highlights.filter { !mine.contains($0.id) && !syncedHighlightIDs.contains($0.id) }
            if !removedElsewhere.isEmpty || !addedElsewhere.isEmpty {
                record.highlights.removeAll { removedElsewhere.contains($0.id) }
                record.highlights += addedElsewhere
                refreshHighlights()
            }
            if (disk.noteUpdatedAt ?? .distantPast) > (record.noteUpdatedAt ?? .distantPast) {
                record.note = disk.note
                record.noteUpdatedAt = disk.noteUpdatedAt
            }
        }
        syncedHighlightIDs = Set(record.highlights.map(\.id))
        CloudStore.save(record)
    }

    // MARK: - Chat context

    func currentContext() -> ChapterContext? {
        if let epub {
            let text = epub.text(ofChapter: chapterIndex)
            return ChapterContext(key: "c\(chapterIndex)", title: epub.chapterTitle(chapterIndex), text: String(text.prefix(180_000)))
        }
        guard let pdf else { return nil }
        let section = pdfSection()
        var text = ""
        for i in section.range {
            if let s = pdf.page(at: i)?.string { text += "\n\n[Page \(i + 1)]\n" + s }
            if text.count > 180_000 { break }
        }
        return ChapterContext(key: "p\(section.range.lowerBound)-\(section.range.upperBound)", title: section.title, text: text)
    }

    /// The outline section containing a page, capped to a reasonable size.
    func pdfSection(for page: Int? = nil) -> (title: String, range: ClosedRange<Int>) {
        let current = page ?? pageIndex
        let count = pdf?.pageCount ?? 1
        let starts: [(Int, String)] = toc.compactMap { e in
            if case .page(let p)? = e.target { return (p, e.title) }
            return nil
        }.sorted { $0.0 < $1.0 }
        if let section = starts.last(where: { $0.0 <= current }) {
            let nextStart = starts.first { $0.0 > section.0 }?.0 ?? count
            let lower = max(section.0, current - 25)
            let upper = min(max(nextStart - 1, current), lower + 40, count - 1)
            return (section.1, lower...max(lower, upper))
        }
        let lower = max(0, current - 1), upper = min(count - 1, current + 2)
        return ("Pages \(lower + 1)–\(upper + 1)", lower...max(lower, upper))
    }

    // MARK: - Persistence

    private func savePosition() {
        record.position = ReadingPosition(chapter: epub != nil ? chapterIndex : nil,
                                          fraction: epub != nil ? chapterFraction : nil,
                                          page: pdf != nil ? pageIndex : nil)
        record.progress = progress
        onProgress?(bookID, progress)
        persist()
    }

    private func persist() {
        record.updatedAt = Date()
        guard !saveBlocked else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.writeRecord()
        }
    }

    /// Writes the record as soon as a book is opened, so other devices learn its title and can list it.
    func announce() {
        guard !saveBlocked, case .missing = CloudStore.loadResult(bookID) else { return }
        CloudStore.save(record)
    }

    func flush() {
        saveTask?.cancel()
        writeRecord()
        study.flush()
    }

    // MARK: - Catch me up

    func openCatchUp() {
        if catchUp.context == nil || catchUp.context?.sources.isEmpty == true {
            let previous = CatchUpContext(record: previousRecord, epub: epub)
            catchUp.context = previous.sources.isEmpty ? CatchUpContext(record: record, epub: epub) : previous
        }
        showCatchUp = true
    }

    /// Capture only text visible in the foreground reader, never an entire unread chapter.
    func captureReadPassage() async {
        guard !showCatchUp, study.tab == nil else { pendingReadPassage = nil; return }
        #if os(macOS)
        guard NSApp.isActive else { pendingReadPassage = nil; return }
        #else
        guard UIApplication.shared.applicationState == .active else { pendingReadPassage = nil; return }
        #endif
        let position = ReadingPosition(chapter: epub != nil ? chapterIndex : nil,
                                       fraction: epub != nil ? chapterFraction : nil,
                                       page: pdf != nil ? pageIndex : nil)
        let sectionTitle = currentChapterTitle
        let text: String
        if let webView, webView.window != nil, !webView.isLoading,
           let pageURL = webView.url, epub?.spineIndex(of: pageURL) == chapterIndex {
            text = (try? await webView.evaluateJavaScript(ReaderScripts.visiblePassage)) as? String ?? ""
        } else if let pdfView, pdfView.window != nil, let page = pdf?.page(at: pageIndex) {
            let visible = pdfView.convert(pdfView.bounds, to: page).intersection(page.bounds(for: .cropBox))
            text = visible.isNull ? "" : (page.selection(for: visible)?.string ?? "")
        } else { return }
        guard !Task.isCancelled, !showCatchUp, study.tab == nil,
              position.chapter == (epub != nil ? chapterIndex : nil),
              position.fraction == (epub != nil ? chapterFraction : nil),
              position.page == (pdf != nil ? pageIndex : nil) else { return }
        let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2500))
        guard excerpt.count >= 40 else { pendingReadPassage = nil; return }
        let passage = ReadPassage(text: excerpt, title: sectionTitle, position: position)
        let previous = pendingReadPassage
        pendingReadPassage = passage
        // Two consecutive samples avoid recording passages merely flashed past while scrolling.
        guard previous?.text == excerpt, previous?.position.chapter == position.chapter,
              previous?.position.page == position.page else { return }
        let passages = record.readPassages ?? []
        if passages.last?.text == excerpt, passages.last?.position.chapter == position.chapter,
           passages.last?.position.page == position.page {
            if passage.date.timeIntervalSince(record.lastReadAt ?? .distantPast) >= 60 {
                record.lastReadAt = passage.date
                persist()
            }
            return
        }
        record.readPassages = ReadPassage.recent(passages + [passage])
        record.lastReadAt = passage.date
        persist()
    }

    func revealCatchUpSource(_ source: CatchUpSource) {
        showCatchUp = false
        study.tab = nil
        if let highlight = source.highlight { reveal(highlight) }
        else if let chapter = source.position.chapter {
            goToChapter(chapter, anchor: .fraction(source.position.fraction ?? 0))
        } else if let page = source.position.page { goToPage(page) }
    }

    // MARK: - Study

    /// Stable id for the section the study tools work on.
    var sectionKey: String {
        if epub != nil { return "c\(chapterIndex)" }
        let starts = toc.compactMap { e -> Int? in
            if case .page(let p)? = e.target { return p }
            return nil
        }
        if let start = starts.filter({ $0 <= pageIndex }).max() { return "s\(start)" }
        return "pg\(pageIndex)"
    }

    func currentSection() -> StudySection? {
        guard let context = currentContext(), context.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 200 else { return nil }
        return StudySection(key: sectionKey, title: context.title, text: context.text)
    }

    /// Titles of the sections before the current one, for the primer.
    var earlierSectionTitles: [String] {
        if let epub {
            var seen = Set<String>()
            return (0..<chapterIndex).map(epub.chapterTitle).filter { seen.insert($0).inserted }
        }
        return toc.compactMap { e -> String? in
            if case .page(let p)? = e.target, p < pageIndex, e.level == 0 { return e.title }
            return nil
        }
    }

    var sectionHighlights: [Highlight] {
        if epub != nil { return chapterHighlights(chapterIndex) }
        let range = pdfSection().range
        return record.highlights.filter { $0.page.map(range.contains) ?? false }
    }

    /// Jumps to a section saved by `sectionKey`. Safe to call before the reader view exists.
    func jump(toSectionKey key: String) {
        if key.hasPrefix("c"), let i = Int(key.dropFirst()), let epub, epub.spine.indices.contains(i) {
            goToChapter(i)
        } else if let pdf, let p = Int(key.drop { !$0.isNumber }), p < pdf.pageCount {
            if pdfView != nil { goToPage(p) } else { pageIndex = p }
        }
    }

    /// Closes the study panel and scrolls the text to a phrase quoted from it.
    func showPassage(_ quote: String) {
        study.tab = nil
        let words = quote.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return }
        if let epub {
            let text = epub.text(ofChapter: chapterIndex)
            // Claude's quote may drift from the text; fall back to shorter prefixes until one matches.
            for n in [words.count, 6, 4, 3] where n <= words.count {
                let query = words.prefix(n).joined(separator: " ")
                guard let pattern = BookSearch.pattern(for: query),
                      text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                goToChapter(chapterIndex, anchor: .search(query, 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, !self.search.isActive else { return }
                    self.js("folio.clearFind()")
                }
                return
            }
        } else if let pdf {
            for n in [words.count, 6, 4, 3] where n <= words.count {
                let query = words.prefix(n).joined(separator: " ")
                let range = pdfSection().range
                let hits = pdf.findString(query, withOptions: [.caseInsensitive])
                guard let hit = hits.first(where: { s in s.pages.first.map { range.contains(pdf.index(for: $0)) } ?? false }) ?? hits.first else { continue }
                pdfView?.go(to: hit)
                pdfView?.setCurrentSelection(hit, animate: true)
                return
            }
        }
    }

    /// Makes a card from a highlight, in the section the highlight belongs to.
    func makeCard(from h: Highlight) {
        if let epub, let href = h.chapterHref, let idx = epub.spineIndex(forHref: href), idx != chapterIndex {
            goToChapter(idx, anchor: .highlight(h.id))
        } else if pdf != nil, let page = h.page, !pdfSection().range.contains(page) {
            goToPage(page)
        }
        study.makeCard(from: h.text)
    }

    func cardFromSelection() {
        let done: (String?) -> Void = { [weak self] text in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 8 else { return }
            self?.study.makeCard(from: text)
        }
        if kind == .epub {
            webView?.evaluateJavaScript("window.getSelection().toString() || window.folio.focusedText()") { value, _ in done(value as? String) }
        } else {
            done(pdfView?.currentSelection?.string ?? pdfView?.focusedText)
        }
    }

    func seekVideo(_ seconds: Double) {
        videoSeek = VideoSeek(time: seconds, token: videoSeek.token + 1, startsThere: !showVideo)
        showVideo = true
    }

    func toggleVideo() {
        videoSeek.startsThere = false
        showVideo.toggle()
    }

    private func js(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    static func json(_ h: Highlight) -> String {
        let dict: [String: Any] = ["id": h.id, "start": h.start ?? 0, "end": h.end ?? 0, "color": h.color.rawValue]
        return (try? String(data: JSONSerialization.data(withJSONObject: dict), encoding: .utf8)) ?? "{}"
    }

    static func json(_ hs: [Highlight]) -> String {
        "[" + hs.map(json).joined(separator: ",") + "]"
    }
}
