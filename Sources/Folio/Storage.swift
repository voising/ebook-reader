import CryptoKit
import Foundation
import SwiftUI

/// A synced type that can absorb a conflicting copy of itself made on another device.
protocol CloudMergeable {
    mutating func merge(_ other: Self)
}

/// Where Folio keeps everything that syncs: one JSON file per book for highlights and positions,
/// the study data, the covers and (in the iCloud container) the book files themselves.
///
/// - Signed builds with the iCloud entitlement use the app's iCloud container, shared with the iPad.
/// - The ad-hoc `build.sh` Mac build has no container and keeps using a folder in iCloud Drive.
/// - With no iCloud at all, everything stays on this device.
enum CloudStore {
    static let containerID = "iCloud.com.voz.folio"

    enum Backing { case container, driveFolder, local }

    #if os(macOS)
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    /// The pre-container location (`build.sh` builds still use it).
    static var legacyRoot: URL {
        let base = FileManager.default.fileExists(atPath: iCloudDrive.path) ? iCloudDrive : AppPaths.support
        return base.appendingPathComponent("Folio", isDirectory: true)
    }
    #endif

    private static let resolved: (backing: Backing, root: URL) = {
        let fm = FileManager.default
        // `-storageRoot <path>` keeps everything in a folder of your choosing (used for testing).
        if let override = UserDefaults.standard.string(forKey: "storageRoot") {
            return (.local, URL(fileURLWithPath: override, isDirectory: true))
        }
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            return (.container, container.appendingPathComponent("Folio", isDirectory: true))
        }
        #if os(macOS)
        return (fm.fileExists(atPath: iCloudDrive.path) ? .driveFolder : .local, legacyRoot)
        #else
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (.local, documents.appendingPathComponent("Folio", isDirectory: true))
        #endif
    }()

    static var backing: Backing { resolved.backing }

    static var isUsingICloud: Bool { backing != .local }

    static let root: URL = {
        try? FileManager.default.createDirectory(at: resolved.root, withIntermediateDirectories: true)
        return resolved.root
    }()

    private static func directory(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let booksDir = directory("Books")

    /// Book files Folio manages itself, named `<bookID>.<ext>`. Nil for the iCloud Drive folder build,
    /// where books stay wherever they are on the Mac.
    static let filesDir: URL? = {
        #if os(macOS)
        guard backing == .container || UserDefaults.standard.string(forKey: "storageRoot") != nil else { return nil }
        #endif
        return directory("Files")
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

    /// True if the file is here, or is known to iCloud but not downloaded yet.
    static func isPresent(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) -> ReadResult<T> {
        // Let this device's own queued saves land first, so a read never sees an older copy than we wrote.
        writer.sync {}
        let fm = FileManager.default
        try? fm.startDownloadingUbiquitousItem(at: url)
        if !fm.fileExists(atPath: url.path) {
            return isPresent(url) ? .unreadable : .missing
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

    /// Like `read`, and also folds in any conflicting versions iCloud kept when two devices saved at once.
    static func readSynced<T: Codable & CloudMergeable>(_ type: T.Type, at url: URL) -> ReadResult<T> {
        let result = read(type, at: url)
        guard case .value(var value) = result,
              let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return result }
        var merged = false
        for version in conflicts {
            // A version that can't be read yet stays unresolved, to be folded in on a later read.
            guard let data = try? Data(contentsOf: version.url), let other = try? decoder.decode(T.self, from: data) else { continue }
            value.merge(other)
            version.isResolved = true
            try? version.remove()
            merged = true
        }
        guard merged else { return result }
        write(value, to: url)
        return .value(value)
    }

    /// One serial queue, so two quick saves of the same file always land in order.
    private static let writer = DispatchQueue(label: "folio.cloud-write", qos: .utility)

    static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        writer.async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
                try? data.write(to: writeURL, options: .atomic)
            }
        }
    }

    // MARK: Book files

    static func bookFile(id: String, kind: BookKind) -> URL? {
        filesDir?.appendingPathComponent("\(id).\(kind.rawValue)")
    }

    /// Copies a book into the managed folder (once) and returns the managed copy. Without a managed
    /// folder the book is opened where it is.
    static func importBook(_ url: URL) throws -> URL {
        guard let filesDir else { return url }
        if url.deletingLastPathComponent().standardizedFileURL.path == filesDir.standardizedFileURL.path { return url }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard ext == "epub" || ext == "pdf" else { throw BookError.unsupported }
        let dest = filesDir.appendingPathComponent("\(try BookIdentity.id(for: url)).\(ext)")
        if !isPresent(dest) {
            do { try FileManager.default.copyItem(at: url, to: dest) } catch {
                // Fine if something else (the first-run migration, another window) put it there meanwhile.
                guard isPresent(dest) else { throw error }
            }
        }
        return dest
    }

    /// Waits for iCloud to bring a file down to this device.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 180) async throws {
        let fm = FileManager.default
        func isCurrent() -> Bool {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard fm.fileExists(atPath: url.path) else { return false }
            let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values?.isUbiquitousItem == true else { return true }
            return values?.ubiquitousItemDownloadingStatus == .current
        }
        if isCurrent() { return }
        guard isPresent(url) else { throw BookError.missingFile }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(400))
            if isCurrent() { return }
        }
        throw BookError.notDownloaded
    }

    static func removeBookFile(id: String, kind: BookKind) {
        guard let url = bookFile(id: id, kind: kind), isPresent(url) else { return }
        writer.async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
    }

    #if os(macOS)
    // MARK: Moving into the iCloud container

    /// The first time a Mac build gets the container, copies what the earlier builds saved into it: records,
    /// study data and covers here (quick, done before anything is read), book files in `migrateBooks`.
    /// Copies only what's missing and never deletes the originals, so it is safe to run again.
    static func migrateData() {
        let flag = "migratedToContainer.data.v1"
        guard backing == .container, !UserDefaults.standard.bool(forKey: flag) else { return }
        copyMissing(from: legacyRoot.appendingPathComponent("Books"), to: booksDir, ext: "json")
        copyMissing(from: legacyRoot.appendingPathComponent("Learn"), to: learnDir, ext: "json")
        copyMissing(from: AppPaths.localCovers, to: AppPaths.covers, ext: "png")
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// Copies the shelf's book files into the container so other devices can open them.
    static func migrateBooks(_ library: [LibraryItem]) {
        let flag = "migratedToContainer.books.v1"
        guard backing == .container, !UserDefaults.standard.bool(forKey: flag) else { return }
        let fm = FileManager.default
        for item in library where fm.fileExists(atPath: item.path) {
            guard let dest = bookFile(id: item.id, kind: item.kind), !isPresent(dest) else { continue }
            try? fm.copyItem(at: URL(fileURLWithPath: item.path), to: dest)
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    private static func copyMissing(from source: URL, to dest: URL, ext: String) {
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == ext {
            let target = dest.appendingPathComponent(file.lastPathComponent)
            if !isPresent(target) { try? fm.copyItem(at: file, to: target) }
        }
    }
    #endif

    static func loadResult(_ bookID: String) -> ReadResult<BookRecord> {
        readSynced(BookRecord.self, at: fileURL(bookID))
    }

    static func load(_ bookID: String) -> BookRecord? {
        if case .value(let record) = loadResult(bookID) { return record }
        return nil
    }

    static func save(_ record: BookRecord) {
        write(record, to: fileURL(record.bookID))
    }

    // MARK: Learning data (separate files, so the highlight records keep their shape)

    static let learnDir = directory("Learn")

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

    static let localCovers: URL = {
        let dir = caches.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Covers travel with the book files when Folio manages them, so a book shows its cover before it is downloaded.
    static let covers: URL = {
        guard CloudStore.filesDir != nil else { return localCovers }
        let dir = CloudStore.root.appendingPathComponent("Covers", isDirectory: true)
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

extension LibraryStore {
    /// Brings this device's shelf in line with the managed book folder: adds books that arrived from
    /// another device, drops ones that were removed there, and refreshes progress.
    static func reconcile(_ items: [LibraryItem], open: String?) -> [LibraryItem] {
        // If the folder can't be listed right now, leave the shelf alone rather than treat it as empty.
        guard let filesDir = CloudStore.filesDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: filesDir.path) else { return items }
        var files: [String: (name: String, kind: BookKind)] = [:]
        for raw in names {
            // Not-yet-downloaded files can appear as ".<name>.icloud".
            var name = raw
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            let url = URL(fileURLWithPath: name)
            guard let kind = BookKind(rawValue: url.pathExtension.lowercased()) else { continue }
            files[url.deletingPathExtension().lastPathComponent] = (name, kind)
        }
        // Ask iCloud for the covers up front; they are small and the shelf looks bare without them.
        for id in files.keys { try? FileManager.default.startDownloadingUbiquitousItem(at: AppPaths.cover(for: id)) }
        let managed = filesDir.standardizedFileURL.path
        var out = items.filter { item in
            // A book that lived in the managed folder and is gone from it was removed on another device.
            let wasManaged = URL(fileURLWithPath: item.path).deletingLastPathComponent().standardizedFileURL.path == managed
            return !wasManaged || files[item.id] != nil
        }
        for (id, file) in files {
            let path = filesDir.appendingPathComponent(file.name).path
            if let i = out.firstIndex(where: { $0.id == id }) {
                out[i].path = path
                if id != open, let record = CloudStore.load(id) { out[i].progress = record.progress }
            } else if let record = CloudStore.load(id) {
                // The record carries the title; until it has synced the book isn't listed.
                out.append(LibraryItem(id: id, path: path, title: record.title, author: record.author, kind: file.kind,
                                       lastOpened: record.updatedAt, progress: record.progress))
            }
        }
        return out
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
    static func savePNG(_ image: PlatformImage, to url: URL, maxHeight: CGFloat = 520) {
        let scale = min(1, maxHeight / max(image.size.height, 1))
        let size = CGSize(width: round(image.size.width * scale), height: round(image.size.height * scale))
        guard size.width > 0, size.height > 0 else { return }
        #if os(macOS)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        try? data.write(to: url)
        #endif
    }
}
