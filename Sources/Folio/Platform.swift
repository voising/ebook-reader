import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
typealias PlatformView = UIView

extension UIColor {
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    static var windowBackgroundColor: UIColor { .systemBackground }
    static var underPageBackgroundColor: UIColor { .secondarySystemBackground }
    static var findHighlightColor: UIColor { .systemYellow }
    static var textBackgroundColor: UIColor { .secondarySystemBackground }
}
#endif

enum Platform {
    /// Claude runs through the `claude` command on the Mac. The iPad shows what the Mac generated.
    #if os(macOS)
    static let hasClaude = true
    #else
    static let hasClaude = false
    #endif

    static let claudeUnavailable = "Claude runs in Folio on your Mac. What it generates there shows up here through iCloud."

    static var shiftIsDown: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Posted when the app comes back to the front, which is when synced changes are picked up.
    static var didBecomeActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    /// Posted when the app is about to stop running in the foreground; unsaved state is flushed here.
    static var willStop: Notification.Name {
        #if os(macOS)
        NSApplication.willTerminateNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }
}

extension Color {
    init(platform color: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: color)
        #else
        self.init(uiColor: color)
        #endif
    }
}

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension PlatformColor {
    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

extension PlatformImage {
    static func load(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }
}

// MARK: - Wrapping AppKit / UIKit views

/// One representable protocol for both platforms: implement `makeView` and `updateView`.
#if os(macOS)
protocol PlatformViewRepresentable: NSViewRepresentable where NSViewType == ViewType {
    associatedtype ViewType: NSView
    @MainActor func makeView(context: Context) -> ViewType
    @MainActor func updateView(_ view: ViewType, context: Context)
}

extension PlatformViewRepresentable {
    @MainActor func makeNSView(context: Context) -> ViewType { makeView(context: context) }
    @MainActor func updateNSView(_ view: ViewType, context: Context) { updateView(view, context: context) }
}
#else
protocol PlatformViewRepresentable: UIViewRepresentable where UIViewType == ViewType {
    associatedtype ViewType: UIView
    @MainActor func makeView(context: Context) -> ViewType
    @MainActor func updateView(_ view: ViewType, context: Context)
}

extension PlatformViewRepresentable {
    @MainActor func makeUIView(context: Context) -> ViewType { makeView(context: context) }
    @MainActor func updateUIView(_ view: ViewType, context: Context) { updateView(view, context: context) }
}
#endif

import WebKit

extension WKWebView {
    /// Lets the SwiftUI background show through until the page paints.
    func makeTransparent() {
        #if os(macOS)
        setValue(false, forKey: "drawsBackground")
        #else
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        #endif
    }

    func setOpacity(_ value: CGFloat, animated: Bool = false) {
        #if os(macOS)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().alphaValue = value
            }
        } else {
            alphaValue = value
        }
        #else
        if animated { UIView.animate(withDuration: 0.18) { self.alpha = value } } else { alpha = value }
        #endif
    }
}

extension View {
    /// Escape clears or dismisses on the Mac; there is no such key event on touch.
    @ViewBuilder func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }
}
