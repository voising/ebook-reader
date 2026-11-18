import AppKit
import CryptoKit
import Foundation

/// Highlights and reading positions live as one JSON file per book in iCloud Drive
/// (~/Library/Mobile Documents/com~apple~CloudDocs/Folio/Books), so every Mac signed
/// into the same account sees them. Falls back to Application Support without iCloud.
enum CloudStore {
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    static var isUsingICloud: Bool {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
    }

    static let root: URL = {
        let base = isUsingICloud ? iCloudDrive : AppPaths.support
        let dir = base.appendingPathComponent("Folio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let booksDir: URL = {
        let dir = root.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(_ bookID: String) -> URL {
        booksDir.appendingPathComponent("\(bookID).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Distinguishes "no file yet" from "a file exists but couldn't be read", so callers never
    /// replace real data with a blank record.
    enum ReadResult<T> {
        case missing
        case value(T)
        case unreadable
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> ReadResult<T> {
        let fm = FileManager.default
        try? fm.startDownloadingUbiquitousItem(at: url)
        if !fm.fileExists(atPath: url.path) {
            let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            return fm.fileExists(atPath: placeholder.path) ? .unreadable : .missing
        }
        var result: ReadResult<T> = .unreadable
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            if data.isEmpty { result = .missing; return }
            if let value = try? decoder.decode(T.self, from: data) { result = .value(value) }
        }
        return result
    }

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        DispatchQueue.global(qos: .utility).async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
                try? data.write(to: writeURL, options: .atomic)
            }
        }
    }

    static func loadResult(_ bookID: String) -> ReadResult<BookRecord> {
        read(BookRecord.self, at: fileURL(bookID))
    }

    static func load(_ bookID: String) -> BookRecord? {
        if case .value(let record) = loadResult(bookID) { return record }
        return nil
    }

    static func save(_ record: BookRecord) {
        write(record, to: fileURL(record.bookID))
    }

    // MARK: Learning data (separate files, so the highlight records keep their shape)

    static let learnDir: URL = {
        let dir = root.appendingPathComponent("Learn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func learnURL(_ bookID: String) -> URL {
        learnDir.appendingPathComponent("\(bookID).json")
    }

    static let libraryLearnURL = learnDir.appendingPathComponent("_library.json")
}

enum AppPaths {
    static let support: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let caches: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Folio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let covers: URL = {
        let dir = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Transcripts imported from YouTube, packaged as EPUBs.
    static let videos: URL = {
        let dir = support.appendingPathComponent("Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func cover(for bookID: String) -> URL {
        covers.appendingPathComponent("\(bookID).png")
    }
}

enum LibraryStore {
    private static let key = "library.v1"

    static func load() -> [LibraryItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [LibraryItem]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum BookIdentity {
    /// Stable across Macs: hash of file size + first 4 MB, independent of file path.
    static func id(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var hasher = SHA256()
        hasher.update(data: Data("\(size)".utf8))
        hasher.update(data: head)
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

enum CoverRenderer {
    static func savePNG(_ image: NSImage, to url: URL, maxHeight: CGFloat = 520) {
        let scale = min(1, maxHeight / max(image.size.height, 1))
        let size = NSSize(width: round(image.size.width * scale), height: round(image.size.height * scale))
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
