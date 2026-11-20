import XCTest
@testable import Folio

final class ArticleTests: XCTestCase {
    private func samplePage() -> Articles.Page {
        Articles.Page(title: "Tom & Jerry <at> the \"Opera\"", byline: "A. Writer", site: "example.org", lang: "en",
                      published: "2026-03-04T10:00:00Z", image: nil, url: "https://example.org/post", words: 400, blocks: [
            .init(t: "p", runs: [.init(s: "First <b>paragraph</b> & more. "), .init(s: "A link", b: true, href: "https://example.org/x?a=1&b=2")]),
            .init(t: "p", runs: [.init(s: "bad link", href: "javascript:alert(1)")]),
            .init(t: "h2", runs: [.init(s: "Second part")]),
            .init(t: "li", runs: [.init(s: "one")]), .init(t: "li", runs: [.init(s: "two")]),
            .init(t: "oli", runs: [.init(s: "first")]),
            .init(t: "quote", runs: [.init(s: "Quoted\u{0} text", i: true)]),
            .init(t: "pre", runs: [.init(s: "if a < b { }")]),
            .init(t: "img", src: "https://example.org/a.png?x=1&y=2", alt: "An \"image\""),
            .init(t: "img", src: "file:///etc/passwd", alt: ""),
            .init(t: "h2", runs: [.init(s: "Third part")]),
            .init(t: "p", runs: [.init(s: String(repeating: "Words and more words. ", count: 60))]),
        ])
    }

    /// The archive we write must open with both extractors (the Mac uses `unzip`, the iPad ours), produce
    /// well-formed chapters, and never carry script, odd links or local file references into the book.
    func testArticleBecomesAReadableBook() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("folio-article-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let source = URL(string: "https://example.org/post?a=1&b=2")!
        let data = Articles.epub(samplePage(), source: source, cover: nil)
        XCTAssertEqual(data, Articles.epub(samplePage(), source: source, cover: nil), "same article, same bytes")
        let file = work.appendingPathComponent("article.epub")
        try data.write(to: file)

        // Our extractor.
        let ours = work.appendingPathComponent("ours")
        try Zip.extract(file, to: ours)
        // The system one.
        let system = work.appendingPathComponent("system")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", file.path, "-d", system.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        for name in ["mimetype", "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/article.xhtml"] {
            XCTAssertEqual(try Data(contentsOf: ours.appendingPathComponent(name)), try Data(contentsOf: system.appendingPathComponent(name)), name)
        }

        let chapter = try String(contentsOf: ours.appendingPathComponent("OEBPS/article.xhtml"), encoding: .utf8)
        for name in ["article.xhtml", "nav.xhtml", "content.opf"] {
            XCTAssertNoThrow(try XMLDocument(contentsOf: ours.appendingPathComponent("OEBPS/" + name), options: []), "\(name) is well-formed")
        }
        XCTAssertFalse(chapter.contains("javascript:"))
        XCTAssertFalse(chapter.contains("file:///"))
        XCTAssertFalse(chapter.contains("<b>"), "page text is escaped, never passed through as markup")
        XCTAssertTrue(chapter.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n<ol>\n<li>first</li>\n</ol>"))

        let book = try BookLoader.load(url: file)
        let epub = try XCTUnwrap(book.epub)
        XCTAssertEqual(book.title, "Tom & Jerry <at> the \"Opera\"")
        XCTAssertEqual(book.author, "A. Writer")
        XCTAssertEqual(epub.identifier, "web:https://example.org/post?a=1&b=2")
        XCTAssertNil(YouTube.videoID(forImported: epub))
        XCTAssertEqual(epub.spine.count, 1)
        XCTAssertEqual(book.toc.map(\.title), ["Tom & Jerry <at> the \"Opera\"", "Second part", "Third part"])
        XCTAssertGreaterThan(epub.text(ofChapter: 0).count, 800)
    }

    func testLinkParsing() {
        XCTAssertEqual(Articles.link(from: " example.org/a b")?.absoluteString, nil)
        XCTAssertEqual(Articles.link(from: "example.org/post")?.absoluteString, "https://example.org/post")
        XCTAssertNil(Articles.link(from: "file:///etc/passwd"))
        XCTAssertNil(Articles.link(from: "javascript:alert(1)"))
        XCTAssertTrue(AddLinkSheet.isVideo("https://youtu.be/aircAruvnKk"))
        XCTAssertFalse(AddLinkSheet.isVideo("https://example.org/aircAruvnKk"))
        XCTAssertTrue(AddLinkSheet.isValid("https://example.org/post"))
    }

    /// Loads a real page in a hidden web view. Set FOLIO_LIVE_ARTICLE to a link.
    @MainActor
    func testReadsALivePage() async throws {
        guard let link = ProcessInfo.processInfo.environment["FOLIO_LIVE_ARTICLE"], let url = Articles.link(from: link) else {
            throw XCTSkip("set FOLIO_LIVE_ARTICLE")
        }
        let page = try await Articles.read(url)
        print("title:", page.title, "| by:", page.byline ?? "-", "| site:", page.site ?? "-", "| words:", page.words, "| blocks:", page.blocks.count)
        print("kinds:", Dictionary(grouping: page.blocks, by: \.t).mapValues(\.count))
        for block in page.blocks.prefix(6) { print(" ", block.t, "·", (block.runs ?? []).map(\.s).joined().prefix(110)) }
        XCTAssertGreaterThan(page.words, 300)
        XCTAssertFalse(page.title.isEmpty)
    }
}
