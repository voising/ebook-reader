import PDFKit
import SwiftUI

enum HubTab: String, CaseIterable, Identifiable {
    case library = "Library", review = "Review", words = "Words", ask = "Ask", map = "Map"
    var id: String { rawValue }
}

/// Learning state across the whole library: the review queue, progress, the cross-book chat and map.
@Observable @MainActor
final class StudyHub {
    private(set) var books: [LearnData] = []
    private(set) var library = LibraryLearnData()
    private(set) var indexStatus: String?
    private(set) var isLinking = false
    var linkError: String?
    var session: [ReviewItem]?
    let chat = ChatModel(scope: .library)

    @ObservationIgnored private var libraryLoaded = false
    @ObservationIgnored private var libraryWritable = true
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    init() {
        chat.onPersist = { [weak self] stored in
            guard let self else { return }
            self.library.chat = stored
            self.saveLibrary()
        }
    }

    // MARK: Loading

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: CloudStore.learnDir, includingPropertiesForKeys: nil)) ?? []
        books = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }.compactMap { url in
            if case .value(let data) = CloudStore.read(LearnData.self, at: url) { return data }
            return nil
        }
        .sorted { ($0.title ?? "") < ($1.title ?? "") }

        if !libraryLoaded {
            libraryLoaded = true
            switch CloudStore.read(LibraryLearnData.self, at: CloudStore.libraryLearnURL) {
            case .value(let saved):
                library = saved
                chat.restore(saved.chat)
            case .missing: break
            case .unreadable: libraryWritable = false
            }
        }
    }

    private func saveLibrary() {
        guard libraryWritable else { return }
        CloudStore.write(library, to: CloudStore.libraryLearnURL)
    }

    // MARK: Review queue

    var allCards: [ReviewItem] {
        books.flatMap { book in
            (book.cards ?? []).map { ReviewItem(card: $0, bookID: book.bookID, source: [book.title, $0.sectionTitle].compactMap { $0 }.joined(separator: " · ")) }
        }
    }

    var due: [ReviewItem] {
        let now = Date()
        return allCards.filter { $0.card.isDue(now) }.sorted { $0.card.due < $1.card.due }
    }

    func startReview(limit: Int = 40) {
        let queue = Array(due.prefix(limit))
        guard !queue.isEmpty else { return }
        session = queue
    }

    func grade(_ item: ReviewItem, _ grade: ReviewGrade) {
        guard let i = books.firstIndex(where: { $0.bookID == item.bookID }) else { return }
        // Re-read first so a review never writes over changes made elsewhere since the hub loaded.
        if case .value(let fresh) = CloudStore.read(LearnData.self, at: CloudStore.learnURL(item.bookID)) { books[i] = fresh }
        guard books[i].grade(item.card.id, grade) != nil else { return }
        CloudStore.write(books[i], to: CloudStore.learnURL(item.bookID))
    }

    // MARK: Stats

    var reviewedToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return books.reduce(0) { $0 + ($1.reviews ?? []).filter { $0.date >= start }.count }
    }

    /// Consecutive days, ending today or yesterday, with at least one review.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(books.flatMap { ($0.reviews ?? []).map { cal.startOfDay(for: $0.date) } })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while days.contains(day) {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86_400)
        }
        return count
    }

    /// Cards that keep being forgotten, worst first.
    var weakCards: [ReviewItem] {
        allCards.filter { $0.card.lapses > 0 }.sorted {
            $0.card.lapses != $1.card.lapses ? $0.card.lapses > $1.card.lapses : $0.card.ease < $1.card.ease
        }
    }

    struct WeakSection: Identifiable {
        let bookID: String
        let book: String
        let key: String
        let title: String
        let score: Int
        var id: String { bookID + key }
    }

    /// Sections whose latest explain-back score is still low.
    var weakSections: [WeakSection] {
        books.flatMap { book -> [WeakSection] in
            var latest: [String: ExplainAttempt] = [:]
            for a in book.attempts ?? [] {
                guard let key = a.sectionKey else { continue }
                if let old = latest[key], old.date > a.date { continue }
                latest[key] = a
            }
            return latest.values.filter { $0.score < 70 }.map {
                WeakSection(bookID: book.bookID, book: book.title ?? "", key: $0.sectionKey ?? "", title: $0.sectionTitle ?? "", score: $0.score)
            }
        }
        .sorted { $0.score < $1.score }
    }

    // MARK: Library index (plain-text copies Claude can search)

    func syncIndex(_ items: [LibraryItem]) {
        guard indexTask == nil else { return }
        indexStatus = "Checking the library…"
        indexTask = Task { [weak self] in
            await Task.detached(priority: .utility) {
                LibraryIndex.sync(items) { done, total, title in
                    Task { @MainActor in self?.indexStatus = "Indexing \(done + 1) of \(total): \(title)" }
                }
            }.value
            self?.indexStatus = nil
            self?.indexTask = nil
        }
    }

    // MARK: Cross-book map

    struct MapNode {
        var node: GraphNode
        var summary: String
        var sources: [(bookID: String, book: String, key: String, section: String)]
    }

    /// Concepts from every mapped section, merged when two sources use the same label.
    func libraryMap(limit: Int = 90) -> (nodes: [MapNode], edges: [GraphEdge], legend: [(String, Color)]) {
        var byLabel: [String: Int] = [:]
        var nodes: [MapNode] = []
        var edgeSet = Set<GraphEdge>()
        var degree: [String: Int] = [:]
        var legend: [(String, Color)] = []
        let mapped = books.filter { !($0.maps ?? [:]).isEmpty }

        for (b, book) in mapped.enumerated() {
            let color = Color.source(b)
            legend.append((book.title ?? "Untitled", color))
            for (key, map) in (book.maps ?? [:]).sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
                var local: [String: String] = [:]
                for n in map.nodes {
                    let norm = Self.normalise(n.label)
                    guard !norm.isEmpty else { continue }
                    let source = (book.bookID, book.title ?? "", key, map.title ?? "")
                    if let i = byLabel[norm] {
                        if !nodes[i].sources.contains(where: { $0.bookID == book.bookID }) {
                            // Shared between sources: neutral colour marks it as a bridge.
                            nodes[i].node.color = Color.primary.opacity(0.75)
                        }
                        nodes[i].sources.append(source)
                        local[n.id] = nodes[i].node.id
                    } else {
                        let id = "k:" + norm
                        byLabel[norm] = nodes.count
                        nodes.append(MapNode(node: GraphNode(id: id, label: n.label, color: color), summary: n.summary ?? "", sources: [source]))
                        local[n.id] = id
                    }
                }
                for e in map.edges ?? [] {
                    guard let a = local[e.from], let c = local[e.to], a != c else { continue }
                    guard !edgeSet.contains(where: { ($0.from == a && $0.to == c) || ($0.from == c && $0.to == a) }) else { continue }
                    edgeSet.insert(GraphEdge(from: a, to: c, label: e.label))
                    degree[a, default: 0] += 1
                    degree[c, default: 0] += 1
                }
            }
        }
        for link in library.links ?? [] {
            guard nodes.contains(where: { $0.node.id == link.from }), nodes.contains(where: { $0.node.id == link.to }) else { continue }
            edgeSet.insert(GraphEdge(from: link.from, to: link.to, label: link.label, dashed: true))
            degree[link.from, default: 0] += 3
            degree[link.to, default: 0] += 3
        }

        // Keep the most connected concepts (and anything bridging two sources) when there are too many to read.
        if nodes.count > limit {
            let keep = Set(nodes.sorted {
                let a = (degree[$0.node.id] ?? 0) + (Set($0.sources.map(\.bookID)).count > 1 ? 100 : 0)
                let b = (degree[$1.node.id] ?? 0) + (Set($1.sources.map(\.bookID)).count > 1 ? 100 : 0)
                return a > b
            }.prefix(limit).map(\.node.id))
            nodes = nodes.filter { keep.contains($0.node.id) }
            edgeSet = edgeSet.filter { keep.contains($0.from) && keep.contains($0.to) }
        }
        let edges = edgeSet.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        return (nodes, edges, legend)
    }

    private static func normalise(_ label: String) -> String {
        label.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var mappedSourceCount: Int { books.filter { !($0.maps ?? [:]).isEmpty }.count }

    /// Asks Claude for links between concepts that come from different sources.
    func findLinks() {
        guard !isLinking else { return }
        let map = libraryMap(limit: 140)
        guard mappedSourceCount >= 2 else { return }
        isLinking = true
        linkError = nil
        // Short aliases in the prompt; the saved links use the stable, label-based ids.
        var prompt = "Concepts, grouped by source:\n"
        var alias: [String: String] = [:]
        let grouped = Dictionary(grouping: map.nodes) { $0.sources.first?.book ?? "" }
        for (book, nodes) in grouped.sorted(by: { $0.key < $1.key }) {
            prompt += "\n## \(book)\n"
            for n in nodes {
                let short = "c\(alias.count + 1)"
                alias[short] = n.node.id
                prompt += "- \(short): \(n.node.label) — \(n.summary.prefix(220))\n"
            }
        }
        prompt += "\nFind the links between sources."
        let sourceOf = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.node.id, Set($0.sources.map(\.bookID))) })
        Task {
            do {
                let dto = try await ClaudeOnce.json(LinksDTO.self, system: StudyPrompts.linksSystem, prompt: prompt)
                library.links = dto.links.compactMap { l -> ConceptEdge? in
                    guard let from = alias[l.from], let to = alias[l.to], from != to,
                          let a = sourceOf[from], let b = sourceOf[to], a != b else { return nil }
                    return ConceptEdge(from: from, to: to, label: l.label)
                }
                library.linksUpdatedAt = Date()
                saveLibrary()
            } catch {
                linkError = error.localizedDescription
            }
            isLinking = false
        }
    }
}

/// Writes each book's text into a folder Claude can grep, one sub-folder per book.
enum LibraryIndex {
    static var root: URL { ClaudeCLI.workingDirectory.appendingPathComponent("Library", isDirectory: true) }

    static func folderName(_ item: LibraryItem) -> String {
        let safe = item.title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
            .collapsed.prefix(60)
        return "\(safe.isEmpty ? "Untitled" : String(safe)) [\(item.id.prefix(6))]"
    }

    static func sync(_ items: [LibraryItem], progress: @Sendable (Int, Int, String) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let wanted = Set(items.map(folderName))
        for stale in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !wanted.contains(stale) && !stale.hasPrefix(".") {
            try? fm.removeItem(at: root.appendingPathComponent(stale))
        }
        let pending = items.filter { !fm.fileExists(atPath: root.appendingPathComponent(folderName($0)).appendingPathComponent(".indexed").path) }
        for (i, item) in pending.enumerated() where fm.fileExists(atPath: item.path) {
            progress(i, pending.count, item.title)
            let dir = root.appendingPathComponent(folderName(item), isDirectory: true)
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let book = try? BookLoader.load(url: item.url) else { continue }
            if let epub = book.epub {
                for index in epub.spine.indices {
                    let text = epub.text(ofChapter: index)
                    guard text.count > 80 else { continue }
                    let title = epub.chapterTitle(index).components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ").prefix(60)
                    try? text.write(to: dir.appendingPathComponent(String(format: "%03d %@.txt", index + 1, String(title))), atomically: true, encoding: .utf8)
                }
            } else if let pdf = book.pdf {
                let step = 15
                for lower in stride(from: 0, to: pdf.pageCount, by: step) {
                    let upper = min(pdf.pageCount, lower + step)
                    var text = ""
                    for p in lower..<upper {
                        if let s = pdf.page(at: p)?.string, !s.isEmpty { text += "[Page \(p + 1)]\n\(s)\n\n" }
                    }
                    guard text.count > 80 else { continue }
                    try? text.write(to: dir.appendingPathComponent(String(format: "pages %04d-%04d.txt", lower + 1, upper)), atomically: true, encoding: .utf8)
                }
            }
            fm.createFile(atPath: dir.appendingPathComponent(".indexed").path, contents: Data())
        }
        // Notes and highlights change, so refresh them every time.
        for item in items {
            let dir = root.appendingPathComponent(folderName(item), isDirectory: true)
            guard fm.fileExists(atPath: dir.path), let record = CloudStore.load(item.id) else { continue }
            let file = dir.appendingPathComponent("notes-and-highlights.md")
            var out = ""
            if let note = record.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { out += "# My notes\n\n\(note)\n\n" }
            if !record.highlights.isEmpty {
                out += "# My highlights\n\n"
                for h in record.highlights {
                    out += "> \(h.text.collapsed)\n"
                    if let where_ = h.chapterTitle ?? h.page.map({ "Page \($0 + 1)" }) { out += "— \(where_)\n" }
                    if let note = h.note, !note.isEmpty { out += "Note: \(note)\n" }
                    out += "\n"
                }
            }
            if out.isEmpty { try? fm.removeItem(at: file) } else { try? out.write(to: file, atomically: true, encoding: .utf8) }
        }
    }
}

// MARK: - Review dashboard

struct ReviewHubView: View {
    @Environment(AppModel.self) private var app
    @Bindable var hub: StudyHub

    var body: some View {
        if let session = hub.session {
            ReviewSessionView(items: session, title: "Review", onGrade: { hub.grade($0, $1) }, onDone: {
                hub.session = nil
                hub.reload()
            })
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        let due = hub.due
        let all = hub.allCards
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review").font(.system(size: 34, weight: .semibold, design: .serif))
                        Text(all.isEmpty ? "Cards you make while reading come back here when they're due."
                             : due.isEmpty ? "Nothing due. Come back later, or make more cards while you read."
                             : "\(due.count) card\(due.count == 1 ? "" : "s") due across \(Set(due.map(\.bookID)).count) source\(Set(due.map(\.bookID)).count == 1 ? "" : "s").")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { hub.startReview() } label: {
                        Label(due.count > 40 ? "Review 40 Cards" : "Start Review", systemImage: "play.fill").padding(.horizontal, 4)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(due.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 14) {
                    StatTile(value: "\(due.count)", label: "Due now")
                    StatTile(value: "\(hub.reviewedToday)", label: "Reviewed today")
                    StatTile(value: "\(hub.streak)", label: "Day streak")
                    StatTile(value: "\(all.count)", label: "Cards in total")
                }

                let withCards = hub.books.filter { !($0.cards ?? []).isEmpty || !($0.attempts ?? []).isEmpty }
                if !withCards.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("By source")
                        ForEach(withCards, id: \.bookID) { book in SourceRow(book: book) }
                    }
                }

                let weakSections = hub.weakSections
                if !weakSections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Sections to revisit")
                        ForEach(weakSections.prefix(6)) { s in
                            HStack(spacing: 12) {
                                ScoreRing(score: s.score, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(s.book).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let item = app.library.first(where: { $0.id == s.bookID }) {
                                    Button("Open") { app.open(item.url, section: s.key) }.controlSize(.small)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                        }
                    }
                }

                let weak = hub.weakCards
                if !weak.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Cards you keep missing")
                        ForEach(weak.prefix(8)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(item.card.lapses)×")
                                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(.orange)
                                    .frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.card.front).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    Text(item.source).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let key = item.card.sectionKey, let book = app.library.first(where: { $0.id == item.bookID }) {
                                    Button("Re-read") { app.open(book.url, section: key) }.controlSize(.small)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 28, weight: .semibold, design: .serif)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

private struct SourceRow: View {
    let book: LearnData

    var body: some View {
        let cards = book.cards ?? []
        let due = cards.filter { $0.isDue() }.count
        let learned = cards.filter { !$0.isNew }.count
        let mature = cards.filter(\.isMature).count
        let scores = (book.attempts ?? []).map(\.score)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title ?? "Untitled").font(.system(size: 13, weight: .semibold, design: .serif)).lineLimit(1)
                Text("\(cards.count) cards · \(due) due · \(mature) mature" + (scores.isEmpty ? "" : " · explain-back avg \(scores.reduce(0, +) / scores.count)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: g.size.width * fraction(learned, cards.count))
                    Capsule().fill(Color.accentColor).frame(width: g.size.width * fraction(mature, cards.count))
                }
            }
            .frame(width: 160, height: 5)
            .help("Dark: remembered for three weeks or more. Light: seen at least once.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private func fraction(_ a: Int, _ b: Int) -> CGFloat { b == 0 ? 0 : CGFloat(a) / CGFloat(b) }
}

// MARK: - Ask the library

struct AskHubView: View {
    @Environment(AppModel.self) private var app
    let hub: StudyHub

    var body: some View {
        VStack(spacing: 0) {
            ChatView(chat: hub.chat, chrome: ChatChrome(
                title: "Ask Your Library",
                subtitle: "\(app.library.count) source\(app.library.count == 1 ? "" : "s")",
                emptyTitle: "Ask across everything you've read.",
                emptyDetail: "Claude searches the full text of every book and video in your library, plus your notes and highlights, and tells you where each point comes from.",
                placeholder: "Ask your library…",
                suggestions: ["What themes come up across my library?", "Which ideas in my highlights contradict each other?",
                              "What should I re-read, based on my notes and highlights?"],
                maxWidth: 760))
            if let status = hub.indexStatus {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .onAppear { hub.syncIndex(app.library) }
    }
}

// MARK: - Library-wide concept map

struct MapHubView: View {
    @Environment(AppModel.self) private var app
    @Bindable var hub: StudyHub
    @State private var selection: String?

    var body: some View {
        let map = hub.libraryMap()
        if map.nodes.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                Text("Your knowledge map starts in a book").font(.system(size: 20, weight: .semibold, design: .serif))
                Text("Open a book, choose Study ▸ Map, and map a section. Every map you make is collected here, and concepts that appear in more than one source are joined.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                GraphView(nodes: map.nodes.map(\.node), edges: map.edges, selection: $selection)
                    .overlay(alignment: .topLeading) { legend(map.legend) }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            if hub.isLinking { ProgressView().controlSize(.small) }
                            Button(hub.isLinking ? "Looking for connections…" : (hub.library.links == nil ? "Find Connections" : "Refresh Connections")) {
                                hub.findLinks()
                            }
                            .disabled(hub.isLinking || hub.mappedSourceCount < 2)
                            .help(hub.mappedSourceCount < 2 ? "Map sections in at least two sources first" : "Ask Claude to link ideas between sources")
                        }
                        .controlSize(.small)
                        .padding(10)
                    }
                Divider().opacity(0.5)
                detail(map.nodes)
            }
        }
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if items.count > 1 {
                HStack(spacing: 6) {
                    Circle().fill(Color.primary.opacity(0.75)).frame(width: 7, height: 7)
                    Text("In more than one source").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 260, alignment: .leading)
    }

    @ViewBuilder private func detail(_ nodes: [StudyHub.MapNode]) -> some View {
        if let n = nodes.first(where: { $0.node.id == selection }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(n.node.label).font(.system(size: 15, weight: .semibold, design: .serif))
                if !n.summary.isEmpty {
                    Text(n.summary).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    ForEach(Array(n.sources.prefix(4).enumerated()), id: \.offset) { _, s in
                        if let item = app.library.first(where: { $0.id == s.bookID }) {
                            Button { app.open(item.url, section: s.key) } label: {
                                Text(s.section.isEmpty ? s.book : "\(s.book) · \(s.section)").lineLimit(1)
                            }
                            .controlSize(.small)
                        } else {
                            Text(s.book).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text("\(nodes.count) concepts from \(hub.mappedSourceCount) source\(hub.mappedSourceCount == 1 ? "" : "s") · dashed lines are connections Claude found between sources")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if let error = hub.linkError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
    }
}
