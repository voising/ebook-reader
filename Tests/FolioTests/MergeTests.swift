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
