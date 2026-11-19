import XCTest
@testable import Folio

final class YouTubeLiveTests: XCTestCase {
    /// Downloads a real transcript with yt-dlp and opens the resulting EPUB. Set FOLIO_LIVE_VIDEO to a YouTube link.
    func testImportBuildsReadableEPUB() async throws {
        guard let link = ProcessInfo.processInfo.environment["FOLIO_LIVE_VIDEO"] else { throw XCTSkip("set FOLIO_LIVE_VIDEO") }
        let url = try await YouTube.importVideo(link) { print("status:", $0) }
        let book = try BookLoader.load(url: url)
        let epub = try XCTUnwrap(book.epub)
        XCTAssertNotNil(YouTube.videoID(forImported: epub))
        print("title:", book.title, "| author:", book.author, "| chapters:", epub.spine.count, "| toc:", book.toc.prefix(3).map(\.title))
        XCTAssertFalse(book.title.isEmpty)
        XCTAssertGreaterThan(epub.spine.count, 0)
        XCTAssertEqual(book.toc.count, epub.spine.count)
        let text = epub.text(ofChapter: 0)
        print("chapter 1:", text.prefix(300))
        XCTAssertGreaterThan(text.count, 200)
        XCTAssertNotNil(epub.coverURL)
    }
}
