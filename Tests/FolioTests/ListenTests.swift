import XCTest
@testable import Folio

final class ListenTests: XCTestCase {
    func testShortParagraphIsOneClipWithItsSentences() {
        let text = "Alice was tired. She had nothing to do!  Was that a rabbit?"
        let clips = ListenText.clips(block: 3, text: text)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].block, 3)
        XCTAssertEqual(clips[0].sentences.count, 3)
        XCTAssertEqual(clips[0].text, "Alice was tired. She had nothing to do! Was that a rabbit?")
        let ns = text as NSString
        XCTAssertTrue(ns.substring(with: clips[0].sentences[1]).hasPrefix("She had nothing"))
        // The sentence ranges tile the paragraph, so the highlight never skips or overlaps text.
        XCTAssertEqual(clips[0].sentences.reduce(0) { $0 + $1.length }, ns.length)
    }

    func testLongParagraphSplitsAtSentenceEnds() {
        let sentence = "This sentence is about forty characters. "
        let text = String(repeating: sentence, count: 60)
        let clips = ListenText.clips(block: 0, text: text, limit: 900)
        XCTAssertGreaterThan(clips.count, 1)
        for clip in clips {
            XCTAssertLessThanOrEqual(clip.text.count, 950)
            XCTAssertTrue(clip.text.hasSuffix("characters."), "clips end on a sentence end")
        }
        XCTAssertEqual(clips.flatMap(\.sentences).count, 60)
    }

    func testTextWithoutSentenceBreaksStillGetsCut() {
        let clips = ListenText.clips(block: 0, text: String(repeating: "word ", count: 1200), limit: 900)
        XCTAssertGreaterThan(clips.count, 2)
        XCTAssertTrue(clips.allSatisfy { $0.text.count <= 1900 })
    }

    func testPDFLineBreaksAndHyphensAreTidied() {
        XCTAssertEqual(ListenText.spoken("an impor-\ntant point\nhere"), "an important point here")
        XCTAssertTrue(ListenText.clips(block: 0, text: " \n  — \n").isEmpty, "nothing to say, no clip")
    }
}
