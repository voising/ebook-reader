import SwiftUI

enum BookKind: String, Codable {
    case epub, pdf
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(srgbRed: 1.00, green: 0.80, blue: 0.16, alpha: 1)
        case .green: NSColor(srgbRed: 0.36, green: 0.78, blue: 0.45, alpha: 1)
        case .blue: NSColor(srgbRed: 0.30, green: 0.60, blue: 1.00, alpha: 1)
        case .pink: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.58, alpha: 1)
        case .purple: NSColor(srgbRed: 0.70, green: 0.48, blue: 0.96, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
    var label: String { rawValue.capitalized }
}

struct PageRect: Codable, Hashable {
    var page: Int
    var x: Double, y: Double, w: Double, h: Double

    init(page: Int, rect: CGRect) {
        self.page = page
        x = rect.origin.x; y = rect.origin.y; w = rect.width; h = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct Highlight: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    var color: HighlightColor
    var note: String?
    var createdAt: Date = Date()

    // EPUB location: chapter file (relative to the book root) + character offsets in its body text.
    var chapterHref: String?
    var chapterTitle: String?
    var start: Int?
    var end: Int?

    // PDF location: one rect per selected line, in page space.
    var rects: [PageRect]?

    var page: Int? { rects?.first?.page }
}

struct ReadingPosition: Codable, Hashable {
    var chapter: Int?
    var fraction: Double?
    var page: Int?
}

/// Everything about a book that syncs through iCloud.
struct BookRecord: Codable {
    var bookID: String
    var title: String
    var author: String
    var kind: BookKind
    var highlights: [Highlight] = []
    var position: ReadingPosition?
    var progress: Double = 0
    var note: String?
    var noteUpdatedAt: Date?
    var updatedAt: Date = Date()
}

/// Local (per-Mac) library entry.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id: String
    var path: String
    var title: String
    var author: String
    var kind: BookKind
    var lastOpened: Date
    var progress: Double

    var url: URL { URL(fileURLWithPath: path) }
}

struct TOCEntry: Identifiable, Hashable {
    enum Target: Hashable {
        case chapter(Int, fragment: String?)
        case page(Int)
    }

    let id: Int
    let title: String
    let level: Int
    let target: Target?
}

struct ChapterContext {
    let key: String
    let title: String
    let text: String
}
