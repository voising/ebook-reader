import Foundation

enum StudyTab: String, CaseIterable, Identifiable {
    case primer = "Primer", map = "Map", explain = "Explain Back", cards = "Cards"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .primer: "signpost.right"
        case .map: "point.3.connected.trianglepath.dotted"
        case .explain: "text.bubble"
        case .cards: "rectangle.on.rectangle.angled"
        }
    }
}

/// Per-book learning state: concept maps, primers, flashcards, explain-back attempts and the saved chat.
@Observable @MainActor
final class StudyModel {
    private(set) var data: LearnData
    /// The open study tab, or nil while reading. `-studyTab Map` on the command line opens with one showing.
    var tab: StudyTab? = UserDefaults.standard.string(forKey: "studyTab").flatMap(StudyTab.init(rawValue:))
    private(set) var busy: Set<StudyTab> = []
    var errors: [StudyTab: String] = [:]
    var selectedNode: String?
    var explainDraft = ""
    /// Cards being drilled right now (the "Quiz me" session), if any.
    var quiz: [ReviewItem]?
    private(set) var saveBlocked = false

    @ObservationIgnored weak var reader: ReaderModel?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [StudyTab: Task<Void, Never>] = [:]
    @ObservationIgnored private var dirty = false

    init(bookID: String, title: String, author: String) {
        switch CloudStore.read(LearnData.self, at: CloudStore.learnURL(bookID)) {
        case .value(let saved):
            data = saved
        case .missing:
            data = LearnData(bookID: bookID)
        case .unreadable:
            data = LearnData(bookID: bookID)
            saveBlocked = true
        }
        data.title = title
        data.author = author
    }

    // MARK: Derived

    func map(for key: String) -> ConceptMap? { data.maps?[key] }
    func primer(for key: String) -> Primer? { data.primers?[key] }
    func cards(for key: String) -> [Flashcard] { (data.cards ?? []).filter { $0.sectionKey == key } }
    func attempts(for key: String) -> [ExplainAttempt] { (data.attempts ?? []).filter { $0.sectionKey == key } }
    func isBusy(_ tab: StudyTab) -> Bool { busy.contains(tab) }

    var dueCount: Int {
        let now = Date()
        return (data.cards ?? []).filter { $0.isDue(now) }.count
    }

    // MARK: Generation

    private func begin(_ tab: StudyTab, _ work: @escaping (ReaderModel, StudySection) async throws -> Void) {
        guard !busy.contains(tab), let reader else { return }
        guard let section = reader.currentSection() else {
            errors[tab] = "There isn't enough text in this section to work with."
            return
        }
        errors[tab] = nil
        busy.insert(tab)
        tasks[tab] = Task { [weak self] in
            do {
                try await work(reader, section)
            } catch is CancellationError {
            } catch {
                self?.errors[tab] = error.localizedDescription
            }
            self?.busy.remove(tab)
            self?.tasks[tab] = nil
        }
    }

    func cancel(_ tab: StudyTab) {
        tasks[tab]?.cancel()
    }

    func generateMap() {
        begin(.map) { [weak self] reader, section in
            var map = try await ClaudeOnce.json(ConceptMap.self, system: StudyPrompts.mapSystem,
                                                prompt: StudyPrompts.map(book: reader.title, author: reader.author, section: section)).cleaned
            guard !map.nodes.isEmpty else { throw ClaudeError("Claude returned an empty map. Try again.") }
            map.createdAt = Date()
            guard let self else { return }
            var maps = self.data.maps ?? [:]
            maps[section.key] = map
            self.data.maps = maps
            self.selectedNode = nil
            self.persist()
        }
    }

    func generatePrimer() {
        begin(.primer) { [weak self] reader, section in
            var primer = try await ClaudeOnce.json(Primer.self, system: StudyPrompts.primerSystem,
                                                   prompt: StudyPrompts.primer(book: reader.title, author: reader.author, section: section,
                                                                               earlier: reader.earlierSectionTitles))
            primer.createdAt = Date()
            guard let self else { return }
            var primers = self.data.primers ?? [:]
            primers[section.key] = primer
            self.data.primers = primers
            self.persist()
        }
    }

    func generateCards(count: Int = 8) {
        begin(.cards) { [weak self] reader, section in
            let existing = self?.cards(for: section.key).map(\.front) ?? []
            let dto = try await ClaudeOnce.json(CardsDTO.self, system: StudyPrompts.cardsSystem,
                                                prompt: StudyPrompts.cards(book: reader.title, author: reader.author, section: section,
                                                                           highlights: reader.sectionHighlights.map(\.text),
                                                                           existing: existing, count: count))
            self?.add(dto.cards, section: section)
        }
    }

    /// Turns one highlighted passage into a card.
    func makeCard(from passage: String) {
        tab = .cards
        begin(.cards) { [weak self] reader, section in
            let dto = try await ClaudeOnce.json(CardsDTO.self, system: StudyPrompts.cardsSystem,
                                                prompt: StudyPrompts.card(book: reader.title, author: reader.author, section: section, passage: passage))
            self?.add(Array(dto.cards.prefix(1)), section: section)
        }
    }

    func gradeExplanation() {
        let text = explainDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else {
            errors[.explain] = "Write a few sentences first — whatever you remember."
            return
        }
        begin(.explain) { [weak self] reader, section in
            let dto = try await ClaudeOnce.json(ExplainDTO.self, system: StudyPrompts.explainSystem,
                                                prompt: StudyPrompts.explain(book: reader.title, author: reader.author, section: section, explanation: text))
            guard let self else { return }
            let attempt = ExplainAttempt(id: UUID().uuidString, sectionKey: section.key, sectionTitle: section.title, text: text,
                                         score: min(100, max(0, dto.score ?? 0)), got: dto.got, missed: dto.missed,
                                         misconceptions: dto.misconceptions, feedback: dto.feedback, date: Date())
            var attempts = self.data.attempts ?? []
            attempts.append(attempt)
            self.data.attempts = attempts
            self.explainDraft = ""
            self.add(dto.cards ?? [], section: section)
            self.persist()
        }
    }

    private func add(_ new: [CardsDTO.Card], section: StudySection) {
        var cards = data.cards ?? []
        let known = Set(cards.map { $0.front.lowercased() })
        for c in new where !c.front.isEmpty && !c.back.isEmpty && !known.contains(c.front.lowercased()) {
            cards.append(Flashcard(front: c.front, back: c.back, quote: c.quote, sectionKey: section.key, sectionTitle: section.title))
        }
        data.cards = cards
        persist()
    }

    // MARK: Cards

    func deleteCard(_ id: String) {
        data.cards?.removeAll { $0.id == id }
        quiz?.removeAll { $0.card.id == id }
        persist()
    }

    func deleteAttempt(_ id: String) {
        data.attempts?.removeAll { $0.id == id }
        persist()
    }

    func grade(_ cardID: String, _ grade: ReviewGrade) {
        data.grade(cardID, grade)
        persist()
    }

    func startQuiz(_ cards: [Flashcard]) {
        guard !cards.isEmpty else { return }
        quiz = cards.shuffled().map { ReviewItem(card: $0, bookID: data.bookID, source: $0.sectionTitle ?? "") }
    }

    // MARK: Persistence

    func saveChat(_ chat: StoredChat) {
        data.chat = chat
        persist()
    }

    private func persist() {
        data.updatedAt = Date()
        dirty = true
        guard !saveBlocked else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.flush()
        }
    }

    /// Picks up cards and reviews made on another Mac, and recovers once an unreadable file becomes readable.
    func reloadFromCloud() {
        guard saveBlocked || (!dirty && busy.isEmpty && quiz == nil) else { return }
        switch CloudStore.read(LearnData.self, at: CloudStore.learnURL(data.bookID)) {
        case .value(var disk):
            if saveBlocked {
                // Keep what was made while the file couldn't be read.
                let cardIDs = Set((disk.cards ?? []).map(\.id)), attemptIDs = Set((disk.attempts ?? []).map(\.id))
                disk.cards = (disk.cards ?? []) + (data.cards ?? []).filter { !cardIDs.contains($0.id) }
                disk.attempts = (disk.attempts ?? []) + (data.attempts ?? []).filter { !attemptIDs.contains($0.id) }
                disk.maps = (disk.maps ?? [:]).merging(data.maps ?? [:]) { _, new in new }
                disk.primers = (disk.primers ?? [:]).merging(data.primers ?? [:]) { _, new in new }
                disk.chat = data.chat ?? disk.chat
                disk.title = data.title
                disk.author = data.author
                data = disk
                saveBlocked = false
                if dirty { persist() }
            } else if (disk.updatedAt ?? .distantPast) > (data.updatedAt ?? .distantPast).addingTimeInterval(1) {
                disk.title = data.title
                disk.author = data.author
                disk.chat = data.chat ?? disk.chat
                data = disk
            }
        case .missing:
            if saveBlocked {
                saveBlocked = false
                if dirty { persist() }
            }
        case .unreadable:
            break
        }
    }

    func flush() {
        saveTask?.cancel()
        guard dirty, !saveBlocked else { return }
        dirty = false
        CloudStore.write(data, to: CloudStore.learnURL(data.bookID))
    }
}

/// One card in a review session, tagged with the book it belongs to.
struct ReviewItem: Identifiable, Hashable {
    var card: Flashcard
    var bookID: String
    var source: String

    var id: String { card.id }
}
