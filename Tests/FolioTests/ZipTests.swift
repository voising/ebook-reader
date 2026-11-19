import XCTest
@testable import Folio

final class ZipTests: XCTestCase {
    /// Packs a small tree with the system `zip` (stored + deflated entries) and checks our extractor reproduces it.
    func testExtractMatchesSource() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("folio-zip-\(UUID().uuidString)")
        let source = work.appendingPathComponent("src"), out = work.appendingPathComponent("out")
        try fm.createDirectory(at: source.appendingPathComponent("OEBPS/text"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let files: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "OEBPS/text/chapter 1.xhtml": Data(String(repeating: "<p>Call me Ishmael. Some years ago…</p>\n", count: 400).utf8),
            "OEBPS/empty.css": Data(),
            "OEBPS/blob.bin": Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) }),
        ]
        for (name, data) in files { try data.write(to: source.appendingPathComponent(name)) }

        let archive = work.appendingPathComponent("book.epub")
        for args in [["-X", "-0", "-q", archive.path, "mimetype"], ["-X", "-r", "-q", archive.path, "OEBPS"]] {
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = source
            zip.arguments = args
            try zip.run()
            zip.waitUntilExit()
            XCTAssertEqual(zip.terminationStatus, 0)
        }

        try Zip.extract(archive, to: out)
        for (name, data) in files {
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), data, name)
        }
    }
}
