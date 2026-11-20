import AVFoundation
import NaturalLanguage
import SwiftUI

/// A word saved by double-clicking it while reading. The definition is filled in afterwards by Claude.
struct VocabWord: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var word: String
    /// The sentence the word was found in.
    var context: String?
    var bookID: String?
    /// "Book · Chapter", for display.
    var source: String?
    /// BCP-47 code used to pick the voice, e.g. "en-US".
    var language: String?
    var addedAt = Date()
    var partOfSpeech: String?
    var definition: String?
    var example: String?
    /// Why the last attempt to define it failed; cleared by Retry.
    var error: String?
    /// The word's flashcard in the review queue, made once it has a definition. Shares the word's id.
    var review: Flashcard?

    /// Builds the flashcard: the word on the front, its meaning and your sentence on the back.
    func makeCard() -> Flashcard? {
        guard let definition else { return nil }
        var back = partOfSpeech.map { "(\($0)) " + definition } ?? definition
        if let example { back += "\n\ne.g. " + example }
        var card = Flashcard(front: word, back: back, quote: context, sectionTitle: source)
        card.id = id
        return card
    }
}

struct WordFile: Codable {
    var words: [VocabWord]
    /// Reviews of word cards, for the "reviewed today" count and the streak.
    var reviews: [ReviewLog]?
}

private struct WordEntry: Decodable {
    var partOfSpeech: String?
    var definition: String?
    var example: String?
}

/// The library-wide word list, stored next to the other study data as `Learn/_words.json`.
@Observable @MainActor
final class WordStore {
    /// The source id word cards carry in the review queue (books use their book id).
    static let reviewID = "_words"

    private(set) var words: [VocabWord] = []
    private(set) var reviews: [ReviewLog] = []
    /// The word Claude is defining right now.
    private(set) var definingID: String?
    private(set) var readOnly = false

    /// `-wordsFile <path>` on the command line points the list at another file.
    @ObservationIgnored private let url = UserDefaults.standard.string(forKey: "wordsFile").map { URL(fileURLWithPath: $0) }
        ?? CloudStore.learnDir.appendingPathComponent("_words.json")
    @ObservationIgnored private var fillTask: Task<Void, Never>?
    @ObservationIgnored private var fillTimer: Task<Void, Never>?
    @ObservationIgnored private var lastAddedID: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    init() { reload() }

    // MARK: Storage

    /// Re-reads the list, picking up what another device saved. Every change here is saved at once and
    /// reads wait for those saves, so this never drops something made on this device.
    func reload() {
        switch CloudStore.readSynced(WordFile.self, at: url) {
        case .value(let file):
            words = file.words
            reviews = file.reviews ?? []
            readOnly = false
            // Words defined before cards existed get theirs now.
            var added = false
            for i in words.indices where words[i].review == nil {
                if let card = words[i].makeCard() { words[i].review = card; added = true }
            }
            if added { save() }
        case .missing: readOnly = false
        case .unreadable: readOnly = true
        }
    }

    private func save() {
        guard !readOnly else { return }
        CloudStore.write(WordFile(words: words, reviews: reviews.isEmpty ? nil : reviews), to: url)
    }

    // MARK: Review

    /// Every defined word as a card for the library-wide review queue.
    var reviewItems: [ReviewItem] {
        words.compactMap { word in
            word.review.map { ReviewItem(card: $0, bookID: Self.reviewID, source: ["Words", word.source].compactMap { $0 }.joined(separator: " · ")) }
        }
    }

    func grade(_ cardID: String, _ grade: ReviewGrade) {
        reload()
        guard !readOnly, let i = words.firstIndex(where: { $0.id == cardID }), var card = words[i].review else { return }
        card.apply(grade)
        words[i].review = card
        reviews.append(ReviewLog(date: Date(), cardID: cardID, grade: grade.rawValue))
        if reviews.count > 3000 { reviews.removeFirst(reviews.count - 3000) }
        save()
    }

    func entry(for word: String) -> VocabWord? {
        words.first { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: Adding and removing

    /// Trims surrounding punctuation; nil unless what's left is a single word.
    static func clean(_ raw: String) -> String? {
        let keep = CharacterSet.letters.union(.decimalDigits)
        var scalars = Array(raw.unicodeScalars)
        while let first = scalars.first, !keep.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, !keep.contains(last) { scalars.removeLast() }
        let word = String(String.UnicodeScalarView(scalars))
        guard !word.isEmpty, word.count <= 40,
              word.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !word.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return nil }
        return word
    }

    /// Saves a word once (case-insensitively). Returns the cleaned word, or nil if there was nothing to save.
    @discardableResult
    func add(_ raw: String, context: String?, bookID: String?, source: String?) -> String? {
        reload()
        guard !readOnly, let word = Self.clean(raw) else { return nil }
        lastAddedID = nil
        if words.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) { return word }
        let sentence = context?.collapsed.nilIfEmpty
        let entry = VocabWord(word: word, context: sentence, bookID: bookID, source: source,
                              language: Self.voiceLanguage(for: sentence ?? word))
        words.insert(entry, at: 0)
        lastAddedID = entry.id
        save()
        scheduleFill()
        return word
    }

    /// Takes back the word just saved by a double-click. Words that were already in the list stay.
    func undoAdd(_ raw: String) {
        guard let id = lastAddedID, let word = Self.clean(raw),
              words.first(where: { $0.id == id })?.word.caseInsensitiveCompare(word) == .orderedSame else { return }
        remove(id)
    }

    func remove(_ id: String) {
        reload()
        guard !readOnly else { return }
        words.removeAll { $0.id == id }
        if lastAddedID == id { lastAddedID = nil }
        save()
    }

    // MARK: Definitions

    /// Waits a moment after the double-click, so a word undone straight away never reaches Claude.
    private func scheduleFill() {
        fillTimer?.cancel()
        fillTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.fillMissing()
        }
    }

    func retry(_ id: String) {
        guard let i = words.firstIndex(where: { $0.id == id }) else { return }
        words[i].error = nil
        fillMissing()
    }

    /// Defines every word that has no definition yet, one at a time.
    func fillMissing() {
        guard Platform.hasClaude, fillTask == nil, !readOnly else { return }
        fillTask = Task { [weak self] in
            while let self, let next = self.words.first(where: { $0.definition == nil && $0.error == nil }) {
                self.definingID = next.id
                var entry: WordEntry?
                var failure: String?
                do {
                    entry = try await ClaudeOnce.json(WordEntry.self, system: Self.system, prompt: Self.prompt(for: next))
                } catch {
                    failure = error.localizedDescription
                }
                // The list may have changed on another device while Claude was working.
                self.reload()
                guard let i = self.words.firstIndex(where: { $0.id == next.id }) else { continue }
                if let definition = entry?.definition?.collapsed.nilIfEmpty {
                    self.words[i].definition = definition
                    self.words[i].partOfSpeech = entry?.partOfSpeech?.collapsed.nilIfEmpty
                    self.words[i].example = entry?.example?.collapsed.nilIfEmpty
                    if self.words[i].review == nil { self.words[i].review = self.words[i].makeCard() }
                } else {
                    self.words[i].error = failure ?? "Claude didn't return a definition."
                }
                self.save()
            }
            self?.definingID = nil
            self?.fillTask = nil
        }
    }

    private static let system = """
    You write short dictionary entries for a reader's personal word list. Define the word as it is used in the sentence \
    the reader found it in, in plain language, in the language of that sentence.
    """

    private static func prompt(for word: VocabWord) -> String {
        """
        Word: \(word.word)
        Sentence it appeared in: \(word.context ?? "(not available)")
        Source: \(word.source ?? "(unknown)")

        Return JSON with these string fields:
        - "partOfSpeech": e.g. "noun", "verb", "adjective".
        - "definition": the meaning in this sentence, at most 30 words. If the word is inflected, define its base form and name it.
        - "example": one new short sentence that uses the word with the same meaning.
        """
    }

    // MARK: Speech

    static func voiceLanguage(for text: String) -> String {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        let regional = ["en": "en-US", "fr": "fr-FR", "es": "es-ES", "de": "de-DE", "it": "it-IT", "pt": "pt-PT", "nl": "nl-NL"]
        return regional[code] ?? code
    }

    func speak(_ word: VocabWord) { speak(word.word, language: word.language) }

    /// Says a word by its text alone (used from review cards, which only carry the word).
    func speak(word text: String) { speak(text, language: entry(for: text)?.language) }

    private func speak(_ text: String, language: String?) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let language = language ?? "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(String(language.prefix(2))) }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer.speak(utterance)
    }
}

// MARK: - Words tab

struct WordsHubView: View {
    @Bindable var store: WordStore

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Words").font(.system(size: 34, weight: .semibold, design: .serif))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                if store.words.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "character.book.closed")
                            .font(.system(size: 50, weight: .light)).foregroundStyle(.tertiary)
                        Text("Double-click a word while reading")
                            .font(.system(size: 20, weight: .medium, design: .serif))
                        Text("It lands here with its definition, the sentence you found it in, and a button to hear it.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 90)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(store.words) { word in
                            WordCard(word: word, isDefining: store.definingID == word.id,
                                     onSpeak: { store.speak(word) }, onRetry: { store.retry(word.id) },
                                     onRemove: { withAnimation(.easeOut(duration: 0.2)) { store.remove(word.id) } })
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 36)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            store.reload()
            store.fillMissing()
        }
    }

    private var subtitle: String {
        if store.readOnly { return "The word list couldn't be read from iCloud Drive, so nothing can be saved right now." }
        if store.words.isEmpty { return "Words you double-click while reading are kept here." }
        return "\(store.words.count) word\(store.words.count == 1 ? "" : "s") saved from your reading."
    }
}

private struct WordCard: View {
    let word: VocabWord
    let isDefining: Bool
    let onSpeak: () -> Void
    let onRetry: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.word).font(.system(size: 22, weight: .semibold, design: .serif)).lineLimit(1)
                if let part = word.partOfSpeech {
                    Text(part).font(.system(size: 12, design: .serif)).italic().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onRemove) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .help("Remove from Words")
                Button(action: onSpeak) { Image(systemName: "speaker.wave.2.fill") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Hear it")
            }

            if let definition = word.definition {
                Text(definition).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                if let example = word.example {
                    Text(example).font(.system(size: 12.5)).italic().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = word.error {
                HStack(spacing: 8) {
                    Text(Platform.hasClaude ? "Couldn't get a definition." : "No definition yet. Retry it in Folio on your Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    if Platform.hasClaude { Button("Retry", action: onRetry).controlSize(.small) }
                }
                .help(error)
            } else {
                HStack(spacing: 8) {
                    if isDefining { ProgressView().controlSize(.small) }
                    Text(isDefining ? "Looking it up…" : Platform.hasClaude ? "Waiting for a definition…" : "Your Mac will add the definition.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }

            if let context = word.context {
                Text("“\(context)”")
                    .font(.system(size: 12, design: .serif)).foregroundStyle(.secondary)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
            if let source = word.source {
                Text(source).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Hear It", action: onSpeak)
            Button("Copy Word") {
                Platform.copy(word.word)
            }
            Divider()
            Button("Remove from Words", role: .destructive, action: onRemove)
        }
    }
}

// MARK: - Looking a word up while reading

/// The word just double-clicked in the reader, and where it sits in the reading pane.
struct WordLookup: Equatable {
    let word: String
    /// The word's frame in the reading pane, measured from its top-left corner.
    let anchor: CGRect
}

enum SystemDictionary {
    /// The built-in macOS dictionary's entry for a word, trimmed to its opening senses. Nil on iPad.
    static func define(_ word: String) -> String? {
        #if os(macOS)
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String? else { return nil }
        // Entries read "headword | pronunciation | part of speech senses… DERIVATIVES… ORIGIN…".
        var text = raw
        let parts = raw.components(separatedBy: " | ")
        if parts.count >= 3 { text = parts[0] + " · " + parts[2...].joined(separator: " | ") }
        for marker in [" DERIVATIVES ", " ORIGIN ", " PHRASES ", " PHRASAL VERBS "] {
            if let cut = text.range(of: marker) { text = String(text[..<cut.lowerBound]) }
        }
        text = text.collapsed
        guard text.count > 300 else { return text.nilIfEmpty }
        let head = text.prefix(300)
        return String(head[..<(head.lastIndex(of: " ") ?? head.endIndex)]) + "…"
        #else
        return nil
        #endif
    }
}

/// The card that appears next to a double-clicked word: the dictionary's entry at once, then what
/// Claude says it means in this sentence.
struct LookupCard: View {
    let lookup: WordLookup
    @Bindable var store: WordStore
    let onClose: () -> Void
    @State private var dictionary: String?

    var body: some View {
        let entry = store.entry(for: lookup.word)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lookup.word).font(.system(size: 18, weight: .semibold, design: .serif)).lineLimit(1)
                if let part = entry?.partOfSpeech {
                    Text(part).font(.system(size: 12, design: .serif)).italic().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { store.speak(word: lookup.word) } label: { Image(systemName: "speaker.wave.2.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Hear it")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Close")
            }
            if let definition = entry?.definition {
                Text(definition).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                if let example = entry?.example {
                    Text(example).font(.system(size: 12.5)).italic().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if let dictionary {
                    Text(dictionary).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                if entry?.error != nil {
                    Text("Claude couldn't define it. Retry from the Words tab.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if Platform.hasClaude {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Asking Claude what it means here…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Saved to Words. Your Mac will add the definition.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .task(id: lookup.word) { dictionary = SystemDictionary.define(lookup.word) }
    }
}
