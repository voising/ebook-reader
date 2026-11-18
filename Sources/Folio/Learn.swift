import Foundation

// MARK: - Tutor modes

enum TutorMode: String, CaseIterable, Identifiable {
    case companion, simple, socratic, deeper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .companion: "Companion"
        case .simple: "Explain Simply"
        case .socratic: "Socratic Tutor"
        case .deeper: "Go Deeper"
        }
    }

    var icon: String {
        switch self {
        case .companion: "sparkle"
        case .simple: "lightbulb"
        case .socratic: "questionmark.bubble"
        case .deeper: "arrow.down.right.circle"
        }
    }

    var blurb: String {
        switch self {
        case .companion: "Answers questions about what you're reading."
        case .simple: "Plain words, everyday analogies, one idea at a time."
        case .socratic: "Asks you questions instead of handing over answers."
        case .deeper: "Why it matters, what it connects to, where it's contested."
        }
    }

    var starter: String {
        switch self {
        case .companion: "What are the key ideas here?"
        case .simple: "Explain the main idea of this part as simply as you can"
        case .socratic: "Quiz me on this part, one question at a time"
        case .deeper: "Why does this part matter, and what does it connect to?"
        }
    }

    var instruction: String {
        switch self {
        case .companion:
            """
            Be clear and concise; prefer a few well-formed paragraphs or a short list over long essays. \
            Don't reveal developments beyond the provided section unless the user explicitly asks.
            """
        case .simple:
            """
            The user wants the simplest possible explanation. Use plain words and one concrete everyday analogy \
            or example per idea. Define any term the text takes for granted. Keep it short, then offer one \
            follow-up they could ask to go a level deeper.
            """
        case .socratic:
            """
            Act as a Socratic tutor. Do not hand over explanations up front. Ask ONE focused question at a time \
            that makes the user retrieve or reason about the material, and wait for their answer. When they \
            answer, say precisely what was right and what was missing or wrong (quote the text to settle it), \
            then ask the next question, slightly harder. If they are stuck or say so, give a hint first, and \
            the answer only after a second miss. Keep each turn short.
            """
        case .deeper:
            """
            Go beyond restating the text. Explain why the idea matters, which assumptions it rests on, how it \
            connects to earlier material and to other fields, where it is contested, and how the user could \
            apply it. Clearly label anything that comes from general knowledge rather than the text.
            """
        }
    }
}

// MARK: - Stored learning data (one file per book, every field optional so old files keep decoding)

struct StoredMessage: Codable {
    var role: String
    var text: String
    var quote: String?
    var isError: Bool?
}

struct StoredChat: Codable {
    var messages: [StoredMessage]?
    var sessionID: String?
    var contextKey: String?
    var mode: String?
}

struct ConceptNode: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var kind: String?
    var summary: String?
    var quote: String?

    init(id: String, label: String, kind: String? = nil, summary: String? = nil, quote: String? = nil) {
        self.id = id; self.label = label; self.kind = kind; self.summary = summary; self.quote = quote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.flexString(.id)
        label = try c.flexString(.label)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        quote = try? c.decodeIfPresent(String.self, forKey: .quote)
    }
}

struct ConceptEdge: Codable, Hashable {
    var from: String
    var to: String
    var label: String?

    init(from: String, to: String, label: String? = nil) {
        self.from = from; self.to = to; self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.flexString(.from)
        to = try c.flexString(.to)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
    }
}

struct ConceptMap: Codable {
    var title: String?
    var nodes: [ConceptNode]
    var edges: [ConceptEdge]?
    var createdAt: Date?

    /// Drops edges that point at nodes Claude didn't define.
    var cleaned: ConceptMap {
        var copy = self
        let ids = Set(nodes.map(\.id))
        copy.edges = (edges ?? []).filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
        return copy
    }
}

struct PrimerTerm: Codable, Hashable {
    var term: String
    var meaning: String?
}

struct Primer: Codable {
    var overview: String?
    var questions: [String]?
    var prerequisites: [String]?
    var terms: [PrimerTerm]?
    var createdAt: Date?
}

struct ExplainAttempt: Codable, Identifiable {
    var id: String
    var sectionKey: String?
    var sectionTitle: String?
    var text: String
    var score: Int
    var got: [String]?
    var missed: [String]?
    var misconceptions: [String]?
    var feedback: String?
    var date: Date
}

struct Flashcard: Codable, Identifiable, Hashable {
    var id: String
    var front: String
    var back: String
    var quote: String?
    var sectionKey: String?
    var sectionTitle: String?
    var createdAt: Date
    var due: Date
    /// Days until the next review after the last grade.
    var interval: Double
    var ease: Double
    var reps: Int
    var lapses: Int
    var lastReviewed: Date?

    init(front: String, back: String, quote: String? = nil, sectionKey: String? = nil, sectionTitle: String? = nil) {
        id = UUID().uuidString
        self.front = front; self.back = back; self.quote = quote
        self.sectionKey = sectionKey; self.sectionTitle = sectionTitle
        createdAt = Date(); due = Date()
        interval = 0; ease = 2.5; reps = 0; lapses = 0
    }

    var isNew: Bool { lastReviewed == nil }
    var isMature: Bool { interval >= 21 }
    func isDue(_ now: Date = Date()) -> Bool { due <= now }
}

struct ReviewLog: Codable {
    var date: Date
    var cardID: String
    var grade: Int
}

struct LearnData: Codable {
    var bookID: String
    var title: String?
    var author: String?
    var chat: StoredChat?
    var maps: [String: ConceptMap]?
    var primers: [String: Primer]?
    var cards: [Flashcard]?
    var attempts: [ExplainAttempt]?
    var reviews: [ReviewLog]?
    var updatedAt: Date?

    mutating func log(_ card: Flashcard, _ grade: ReviewGrade) {
        var logs = reviews ?? []
        logs.append(ReviewLog(date: Date(), cardID: card.id, grade: grade.rawValue))
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
        reviews = logs
    }

    /// Applies a grade to one of this book's cards and records it. Returns the updated card.
    @discardableResult
    mutating func grade(_ cardID: String, _ grade: ReviewGrade) -> Flashcard? {
        guard var all = cards, let i = all.firstIndex(where: { $0.id == cardID }) else { return nil }
        all[i].apply(grade)
        cards = all
        log(all[i], grade)
        updatedAt = Date()
        return all[i]
    }
}

/// Library-level data: the cross-book chat and the links Claude found between books.
struct LibraryLearnData: Codable {
    var chat: StoredChat?
    var links: [ConceptEdge]?
    var linksUpdatedAt: Date?
}

// MARK: - Spaced repetition (SM-2, simplified)

enum ReviewGrade: Int, CaseIterable, Identifiable {
    case again = 1, hard, good, easy

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

extension Flashcard {
    /// Days until the card would come back if graded this way now.
    func nextInterval(_ grade: ReviewGrade) -> Double {
        switch grade {
        case .again: return 10.0 / (24 * 60)
        case .hard: return max(1, interval * 1.2)
        case .good:
            if reps == 0 { return 1 }
            if reps == 1 { return 3 }
            return max(interval + 1, interval * ease)
        case .easy:
            if reps == 0 { return 4 }
            return max(interval + 2, interval * ease * 1.3)
        }
    }

    mutating func apply(_ grade: ReviewGrade, now: Date = Date()) {
        let next = nextInterval(grade)
        switch grade {
        case .again:
            lapses += 1
            reps = 0
            ease = max(1.3, ease - 0.2)
        case .hard:
            reps += 1
            ease = max(1.3, ease - 0.15)
        case .good:
            reps += 1
        case .easy:
            reps += 1
            ease = min(3.0, ease + 0.15)
        }
        interval = next
        due = now.addingTimeInterval(next * 86_400)
        lastReviewed = now
    }

    static func intervalLabel(_ days: Double) -> String {
        if days < 1.0 / 24 { return "\(max(1, Int((days * 24 * 60).rounded()))) min" }
        if days < 1 { return "\(Int((days * 24).rounded())) h" }
        if days < 30 { return "\(Int(days.rounded())) d" }
        if days < 365 { return String(format: "%.1f mo", days / 30) }
        return String(format: "%.1f y", days / 365)
    }
}

// MARK: - One-shot Claude calls that return JSON

struct ClaudeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
enum ClaudeOnce {
    private final class Box: @unchecked Sendable {
        var run: ClaudeRun?
        var text = ""
        var result: String?
        var failure: String?
        var done = false
        var cancelled = false
    }

    /// Runs `claude -p` once with no tools and no saved session, and returns the reply text.
    static func text(system: String, prompt: String) async throws -> String {
        let box = Box()
        let args = ["-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--strict-mcp-config",
                    "--no-session-persistence", "--system-prompt", system]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                do {
                    box.run = try ClaudeRun(arguments: args, input: prompt) { event in
                        switch event {
                        case .fullText(let t): box.text += t
                        case .result(let r): box.result = r
                        case .failure(let m): box.failure = m
                        case .finished(let status, let stderr):
                            guard !box.done else { return }
                            box.done = true
                            box.run = nil
                            if box.cancelled {
                                cont.resume(throwing: CancellationError())
                            } else if let failure = box.failure {
                                cont.resume(throwing: ClaudeError(failure))
                            } else if let out = box.result?.nilIfEmpty ?? box.text.nilIfEmpty {
                                cont.resume(returning: out)
                            } else {
                                cont.resume(throwing: ClaudeError(stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                                                                  ?? "claude exited with status \(status)."))
                            }
                        default: break
                        }
                    }
                    if box.cancelled { box.run?.cancel() }
                } catch {
                    box.done = true
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            DispatchQueue.main.async {
                box.cancelled = true
                box.run?.cancel()
            }
        }
    }

    static func json<T: Decodable>(_ type: T.Type, system: String, prompt: String) async throws -> T {
        let raw = try await text(system: system + "\n\nReply with one JSON object and nothing else: no prose before or after, no code fences.",
                                 prompt: prompt)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw ClaudeError("Claude didn't return the expected data. Try again.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(raw[start...end].utf8))
        } catch {
            throw ClaudeError("Couldn't read Claude's reply. Try again.")
        }
    }
}

extension KeyedDecodingContainer {
    /// Accepts a string or a number where a string is expected (models sometimes emit numeric ids).
    func flexString(_ key: Key) throws -> String {
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing \(key.stringValue)"))
    }
}

// MARK: - Prompts

struct StudySection {
    let key: String
    let title: String
    let text: String
}

enum StudyPrompts {
    private static let base = """
    You are the study engine inside a reading app. The user is working through a book or a video transcript \
    and wants to actually learn it. You are given the text of the section they have open. Base everything on \
    that text; do not invent content it doesn't support. Write in the same language as the section.
    """

    private static func header(_ book: String, _ author: String, _ s: StudySection) -> String {
        let by = author.isEmpty ? "" : " by \(author)"
        return "Source: \"\(book)\"\(by)\n\n<section title=\"\(s.title)\">\n\(s.text)\n</section>\n\n"
    }

    // Concept map

    static let mapSystem = base + """


    Build a concept map of the section: the ideas that carry its argument and how they relate.
    Shape: {"title": string, "nodes": [{"id": "n1", "label": string, "kind": string, "summary": string, \
    "quote": string}], "edges": [{"from": "n1", "to": "n2", "label": string}]}
    - 8 to 16 nodes. "label" is 1 to 4 words. "kind" is one of: concept, claim, example, person, term, method.
    - "summary" is one or two sentences saying what the section says about it.
    - "quote" is a short phrase of 4 to 10 consecutive words copied exactly from the section where the idea \
    is introduced, so the app can jump to it.
    - Edges read as a sentence from source to target; "label" is a short verb phrase such as "causes", \
    "is an example of", "depends on", "contrasts with". Every node has at least one edge. Prefer a connected \
    map with one or two central nodes over a flat list.
    """

    static func map(book: String, author: String, section: StudySection) -> String {
        header(book, author, section) + "Map this section."
    }

    // Primer

    static let primerSystem = base + """


    Prepare the user to read this section BEFORE they read it, so they read with purpose. Do not summarise \
    its conclusions; set up the questions it answers.
    Shape: {"overview": string, "questions": [string], "prerequisites": [string], \
    "terms": [{"term": string, "meaning": string}]}
    - "overview": two or three sentences on what the section is about and why it is here.
    - "questions": three or four guiding questions the reader should be able to answer afterwards. Make them \
    require understanding, not lookup.
    - "prerequisites": zero to four ideas the section assumes, each in one sentence; name the earlier section \
    when the list of earlier sections makes that clear.
    - "terms": up to six terms the section leans on, each with a one-line meaning.
    """

    static func primer(book: String, author: String, section: StudySection, earlier: [String]) -> String {
        var p = header(book, author, section)
        if !earlier.isEmpty {
            p += "Earlier sections, in order:\n" + earlier.suffix(40).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return p + "Write the primer."
    }

    // Flashcards

    static let cardsSystem = base + """


    Write flashcards for spaced repetition.
    Shape: {"cards": [{"front": string, "back": string, "quote": string}]}
    - One idea per card. "front" is a question that forces recall or reasoning (why, how, what follows, \
    what distinguishes), never a yes/no question and never one answerable from the wording of the question.
    - "back" is the answer in one to three sentences.
    - "quote" is a phrase of 4 to 10 consecutive words copied exactly from the section that supports the answer.
    - Passages the user highlighted are what they found important: cover those first.
    - Do not repeat cards that already exist.
    """

    static func cards(book: String, author: String, section: StudySection, highlights: [String], existing: [String], count: Int) -> String {
        var p = header(book, author, section)
        if !highlights.isEmpty {
            p += "Passages the user highlighted in this section:\n" + highlights.prefix(30).map { "- \($0.collapsed)" }.joined(separator: "\n") + "\n\n"
        }
        if !existing.isEmpty {
            p += "Cards that already exist (fronts):\n" + existing.suffix(60).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return p + "Write \(count) cards."
    }

    static func card(book: String, author: String, section: StudySection, passage: String) -> String {
        header(book, author, section) + "Write exactly 1 card for this passage the user highlighted:\n<passage>\n\(passage)\n</passage>"
    }

    // Explain-back

    static let explainSystem = base + """


    The user has written, from memory, their own explanation of the section. Grade it against the text like \
    a fair, exacting tutor. Judge understanding, not wording or length.
    Shape: {"score": integer 0-100, "got": [string], "missed": [string], "misconceptions": [string], \
    "feedback": string, "cards": [{"front": string, "back": string}]}
    - "got": the key points they got right, each in a short sentence.
    - "missed": key points of the section that are absent from their explanation.
    - "misconceptions": things they stated that the text contradicts, each with the correction.
    - "feedback": two or three sentences addressed to them: the single most important gap and what to re-read.
    - "cards": one flashcard per missed point or misconception (at most five), so they can drill the gaps.
    - "score": share of the section's key points they demonstrably understood.
    """

    static func explain(book: String, author: String, section: StudySection, explanation: String) -> String {
        header(book, author, section) + "My explanation, written from memory:\n<explanation>\n\(explanation)\n</explanation>"
    }

    // Cross-book links

    static let linksSystem = """
    You connect ideas across a personal library. You are given concepts extracted from several books and \
    videos, each with an id, a label and a short summary. Find the links BETWEEN different sources: the same \
    idea under another name, one idea explaining or contradicting another, a general principle and its instance.
    Shape: {"links": [{"from": id, "to": id, "label": string}]}
    - Only link concepts that come from different sources. Use the ids exactly as given.
    - "label" is a short verb phrase: "same idea as", "explains", "contradicts", "is an instance of", "extends".
    - At most 25 links; prefer the few that are truly illuminating over many weak ones. Return an empty list \
    if nothing really connects.
    """
}

// MARK: - DTOs

struct CardsDTO: Decodable {
    struct Card: Decodable {
        var front: String
        var back: String
        var quote: String?
    }
    var cards: [Card]
}

struct ExplainDTO: Decodable {
    var score: Int?
    var got: [String]?
    var missed: [String]?
    var misconceptions: [String]?
    var feedback: String?
    var cards: [CardsDTO.Card]?
}

struct LinksDTO: Decodable {
    var links: [ConceptEdge]
}
