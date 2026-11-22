import XCTest
@testable import Folio

final class CatchUpTests: XCTestCase {
    private func record() -> BookRecord {
        BookRecord(bookID: "test", title: "A book", author: "An author", kind: .pdf)
    }

    func testOldRecordStillDecodesWithoutReadingHistory() throws {
        let json = #"{"bookID":"b","title":"T","author":"","kind":"pdf","highlights":[],"progress":0,"updatedAt":0}"#
        let decoded = try JSONDecoder().decode(BookRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.readPassages)
        XCTAssertNil(decoded.lastReadAt)
        XCTAssertTrue(CatchUpContext(record: decoded, epub: nil).sources.isEmpty)
    }

    func testPromptIncludesOnlyReadExcerptsNotBookMetadataOrNotes() {
        var book = record()
        book.title = "SPOILER_BOOK_TITLE"
        book.note = "SPOILER_FROM_LATER_NOTE"
        book.position = ReadingPosition(page: 99)
        book.readPassages = [ReadPassage(text: "Only this passage was visible.", title: "SPOILER_CHAPTER_TITLE",
                                         position: ReadingPosition(page: 2))]
        let context = CatchUpContext(record: book, epub: nil)
        XCTAssertEqual(context.sources.count, 1)
        XCTAssertTrue(context.prompt.contains("Only this passage was visible."))
        XCTAssertFalse(context.prompt.contains("SPOILER"))
        XCTAssertEqual(context.sources.first?.position.page, 2)
        XCTAssertEqual(context.position?.page, 99)
    }

    func testLegacyHighlightProvidesARealSourceAndLastNote() {
        var book = record()
        book.note = "My thought"
        let date = Date(timeIntervalSince1970: 100)
        book.highlights = [Highlight(text: "A previously selected passage", color: .yellow, createdAt: date,
                                     rects: [PageRect(page: 3, rect: .zero)])]
        let context = CatchUpContext(record: book, epub: nil)
        XCTAssertEqual(context.sources.first?.highlight?.id, book.highlights[0].id)
        XCTAssertEqual(context.sources.first?.position.page, 3)
        XCTAssertEqual(context.lastReadAt, date)
        XCTAssertEqual(context.note, "My thought")
    }

    func testRecapRejectsUnknownSourcesAndInventedQuotes() throws {
        let source = CatchUpSource(id: "real", text: "A neuron holds an activation between zero and one.",
                                   title: "Neurons", position: ReadingPosition(page: 1))
        let valid = CatchUpRecap.Idea(text: "Neurons hold activations.", sourceID: "real", quote: "A neuron holds an activation")
        let invented = CatchUpRecap.Idea(text: "Spoiler", sourceID: "real", quote: "This occurs in a later chapter.")
        let badID = CatchUpRecap.Idea(text: "Spoiler", sourceID: "fake", quote: valid.quote)
        let recall = CatchUpRecap.Recall(question: "What happens later?", answer: "An invented answer",
                                         sourceID: "real", quote: "Something that was not in the source")
        let result = try CatchUpRecap(ideas: [invented, valid, badID], recall: recall).validated(against: [source])
        XCTAssertEqual(result.ideas.map(\.text), [valid.text])
        XCTAssertNil(result.recall)
        XCTAssertThrowsError(try CatchUpRecap(ideas: [invented, badID]).validated(against: [source]))
    }

    func testValidRecallAndWhitespaceNormalizedCitation() throws {
        let source = CatchUpSource(id: "s", text: "A neuron\nholds an activation.", title: "Source", position: ReadingPosition(page: 0))
        let result = try CatchUpRecap(ideas: [.init(text: "An activation.", sourceID: "s", quote: "A neuron holds an activation.")],
                                     recall: .init(question: "What does a neuron hold?", answer: "An activation.",
                                                   sourceID: "s", quote: "holds an activation.")).validated(against: [source])
        XCTAssertNotNil(result.recall)
    }

    func testHistoryMergeKeepsBothDevicesAndBoundsStorage() throws {
        var first = record(), second = record()
        first.readPassages = (0..<30).map {
            ReadPassage(text: "Passage \($0)", title: "Source", position: ReadingPosition(page: $0),
                        date: Date(timeIntervalSince1970: Double($0)))
        }
        second.readPassages = [ReadPassage(text: "Passage 29", title: "Source", position: ReadingPosition(page: 29),
                                          date: Date(timeIntervalSince1970: 50)),
                               ReadPassage(text: "From another device", title: "Source", position: ReadingPosition(page: 40),
                                           date: Date(timeIntervalSince1970: 60))]
        first.lastReadAt = Date(timeIntervalSince1970: 29)
        second.lastReadAt = Date(timeIntervalSince1970: 60)
        first.merge(second)
        XCTAssertEqual(first.readPassages?.count, 24)
        XCTAssertEqual(first.readPassages?.filter { $0.text == "Passage 29" }.count, 1)
        XCTAssertEqual(first.readPassages?.last?.text, "From another device")
        XCTAssertEqual(first.lastReadAt, second.lastReadAt)
        let decoded = try JSONDecoder().decode(BookRecord.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded.readPassages, first.readPassages)
        XCTAssertEqual(decoded.lastReadAt, first.lastReadAt)
    }
}
