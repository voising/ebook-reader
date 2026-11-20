import XCTest
@testable import Folio

final class MergeTests: XCTestCase {
    private func card(_ id: String, reviewed: Date? = nil) -> Flashcard {
        var c = Flashcard(front: id, back: "a")
        c.id = id
        c.lastReviewed = reviewed
        return c
    }

    /// Saving on one device must take in the other device's changes without resurrecting or losing cards.
    func testAbsorbKeepsBothSidesAndHonoursDeletions() {
        var here = LearnData(bookID: "b")
        here.cards = [card("shared"), card("deleted-there"), card("made-here")]
        let known = LearnData.Known(cards: ["shared", "deleted-there", "deleted-here"], attempts: [])

        var disk = LearnData(bookID: "b")
        disk.cards = [card("shared", reviewed: Date()), card("deleted-here"), card("made-there")]

        here.absorb(disk, known: known)
        let ids = Set((here.cards ?? []).map(\.id))
        XCTAssertEqual(ids, ["shared", "made-here", "made-there"])
        XCTAssertNotNil(here.cards?.first { $0.id == "shared" }?.lastReviewed, "the newer review wins")
    }

    func testAbsorbIsANoOpWhenNothingChangedElsewhere() {
        var here = LearnData(bookID: "b")
        here.cards = [card("a"), card("b"), card("new")]
        var disk = LearnData(bookID: "b")
        disk.cards = [card("a"), card("b")]
        here.absorb(disk, known: LearnData.Known(cards: ["a", "b"], attempts: []))
        XCTAssertEqual((here.cards ?? []).map(\.id), ["a", "b", "new"])
    }

    /// A true iCloud conflict keeps the highlights from both copies.
    func testBookRecordConflictMergeUnionsHighlights() {
        var a = BookRecord(bookID: "b", title: "T", author: "A", kind: .pdf)
        var b = a
        a.highlights = [Highlight(id: "1", text: "one", color: .yellow)]
        b.highlights = [Highlight(id: "1", text: "one", color: .yellow), Highlight(id: "2", text: "two", color: .blue)]
        b.progress = 0.4
        b.updatedAt = a.updatedAt.addingTimeInterval(60)
        a.merge(b)
        XCTAssertEqual(a.highlights.map(\.id), ["1", "2"])
        XCTAssertEqual(a.progress, 0.4)
    }

    func testWordListConflictMergeKeepsDefinedCopy() {
        var a = WordFile(words: [VocabWord(word: "Treacle")])
        var defined = VocabWord(word: "treacle")
        defined.definition = "syrup"
        a.merge(WordFile(words: [defined, VocabWord(word: "mauve")]))
        XCTAssertEqual(a.words.count, 2)
        XCTAssertEqual(a.words.first { $0.word.lowercased() == "treacle" }?.definition, "syrup")
    }
}

final class WordListTests: XCTestCase {
    /// The list saved before word cards existed must still load, or the store would turn read-only.
    func testDecodesListSavedBeforeReviewCards() throws {
        let json = """
        {"words":[{"id":"1","word":"treacle","addedAt":"2026-11-19T10:01:00Z","language":"en-US","partOfSpeech":"noun",
          "definition":"A thick syrup.","example":"Warm treacle.","context":"They lived on treacle.","source":"Alice · Tea"},
         {"id":"2","word":"mauve","addedAt":"2026-11-19T10:02:00Z"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(WordFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.words.count, 2)
        XCTAssertNil(file.words[0].review)
        let card = try XCTUnwrap(file.words[0].makeCard())
        XCTAssertEqual(card.id, "1", "the card shares the word's id, so two devices make the same card")
        XCTAssertEqual(card.front, "treacle")
        XCTAssertTrue(card.back.contains("(noun) A thick syrup."))
        XCTAssertNil(file.words[1].makeCard(), "no card until the word has a definition")
    }

    func testConflictKeepsTheLaterReview() {
        var mine = VocabWord(word: "treacle")
        mine.definition = "syrup"
        mine.review = mine.makeCard()
        var theirs = mine
        theirs.review?.apply(.good)
        var file = WordFile(words: [mine])
        file.merge(WordFile(words: [theirs], reviews: [ReviewLog(date: Date(), cardID: mine.id, grade: 3)]))
        XCTAssertNotNil(file.words[0].review?.lastReviewed)
        XCTAssertEqual(file.reviews?.count, 1)
    }
}
