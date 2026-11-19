import SwiftUI

enum ReaderTheme: String, CaseIterable, Identifiable {
    case auto, paper, sepia, night

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    func resolved(_ scheme: ColorScheme) -> ReaderTheme {
        self == .auto ? (scheme == .dark ? .night : .paper) : self
    }

    var background: PlatformColor {
        switch self {
        case .auto, .paper: PlatformColor(srgbRed: 0.988, green: 0.982, blue: 0.968, alpha: 1)
        case .sepia: PlatformColor(srgbRed: 0.957, green: 0.925, blue: 0.851, alpha: 1)
        case .night: PlatformColor(srgbRed: 0.110, green: 0.106, blue: 0.102, alpha: 1)
        }
    }

    var foreground: PlatformColor {
        switch self {
        case .auto, .paper: PlatformColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)
        case .sepia: PlatformColor(srgbRed: 0.24, green: 0.19, blue: 0.13, alpha: 1)
        case .night: PlatformColor(srgbRed: 0.85, green: 0.83, blue: 0.79, alpha: 1)
        }
    }

    var link: PlatformColor {
        switch self {
        case .auto, .paper: PlatformColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1)
        case .sepia: PlatformColor(srgbRed: 0.55, green: 0.28, blue: 0.10, alpha: 1)
        case .night: PlatformColor(srgbRed: 0.90, green: 0.66, blue: 0.42, alpha: 1)
        }
    }

    var isDark: Bool { self == .night }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case serif, sans
    var id: String { rawValue }
    var label: String { self == .serif ? "Serif" : "Sans" }
    var css: String {
        switch self {
        case .serif: "ui-serif, \"New York\", \"Iowan Old Style\", Georgia, serif"
        case .sans: "-apple-system, \"SF Pro Text\", \"Helvetica Neue\", sans-serif"
        }
    }
}

enum ReaderWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var css: String {
        switch self {
        case .narrow: "32em"
        case .medium: "38em"
        case .wide: "50em"
        }
    }
}

@Observable @MainActor
final class ReaderSettings {
    static let shared = ReaderSettings()
    private let defaults = UserDefaults.standard

    var theme: ReaderTheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    var font: ReaderFont { didSet { defaults.set(font.rawValue, forKey: "font") } }
    var width: ReaderWidth { didSet { defaults.set(width.rawValue, forKey: "width") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var lineHeight: Double { didSet { defaults.set(lineHeight, forKey: "lineHeight") } }

    private init() {
        theme = ReaderTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .auto
        font = ReaderFont(rawValue: defaults.string(forKey: "font") ?? "") ?? .serif
        width = ReaderWidth(rawValue: defaults.string(forKey: "width") ?? "") ?? .medium
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 19
        lineHeight = defaults.object(forKey: "lineHeight") as? Double ?? 1.65
    }

    func snapshot(_ scheme: ColorScheme) -> ThemeSnapshot {
        let t = theme.resolved(scheme)
        return ThemeSnapshot(
            vars: [
                "--folio-bg": t.background.hex,
                "--folio-fg": t.foreground.hex,
                "--folio-link": t.link.hex,
                "--folio-font": font.css,
                "--folio-size": "\(Int(fontSize))px",
                "--folio-lh": String(format: "%.2f", lineHeight),
                "--folio-width": width.css,
                "--folio-hl-a": t.isDark ? "0.38" : "0.45",
            ],
            theme: t
        )
    }
}

struct ThemeSnapshot: Equatable {
    let vars: [String: String]
    let theme: ReaderTheme
}
