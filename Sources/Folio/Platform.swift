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

extension PlatformColor {
    /// The app's one accent: the warm brown of the reader's links, lighter in the dark.
    static let folioAccent: PlatformColor = {
        let light = PlatformColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1)
        let dark = PlatformColor(srgbRed: 0.80, green: 0.52, blue: 0.28, alpha: 1)
        #if os(macOS)
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        #else
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }()
}

extension Color {
    static let folioAccent = Color(platform: PlatformColor.folioAccent)
}

extension Font {
    /// A system font at a fixed size on the Mac. On iPad it follows the Dynamic Type setting, up to
    /// 1.6 times the size, which is as far as the fixed-width parts of the layout stretch.
    static func scaled(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        #if os(iOS)
        .system(size: min(UIFontMetrics.default.scaledValue(for: size), size * 1.6), weight: weight, design: design)
        #else
        .system(size: size, weight: weight, design: design)
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

#if os(iOS)
import UIKit

/// In landscape, a double tap anywhere on the book scrolls down by almost a screen, keeping a few lines
/// of overlap so the eye can find its place. In portrait it does nothing and the view's own double tap
/// (zoom, word selection) still works.
final class PageDownTap: NSObject, UIGestureRecognizerDelegate {
    private weak var host: UIView?
    private let scrollView: () -> UIScrollView?
    private let recognizer = UITapGestureRecognizer()

    init(on host: UIView, scrollView: @escaping () -> UIScrollView?) {
        self.host = host
        self.scrollView = scrollView
        super.init()
        recognizer.numberOfTapsRequired = 2
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(fired))
        host.addGestureRecognizer(recognizer)
    }

    private var isLandscape: Bool {
        guard let window = host?.window else { return false }
        if let scene = window.windowScene { return scene.effectiveGeometry.interfaceOrientation.isLandscape }
        return window.bounds.width > window.bounds.height
    }

    @objc private func fired() { scrollView()?.pageDown() }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { isLandscape }

    /// The view's own double taps (PDF zoom, web view zoom/selection) wait for this one to fail,
    /// so in landscape the page turn wins.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        (other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !((other as? UITapGestureRecognizer)?.numberOfTapsRequired == 2)
    }
}

extension UIScrollView {
    /// Scrolls down by almost a screen, keeping a few lines of overlap so the eye can find its place.
    func pageDown() {
        let inset = adjustedContentInset
        let visible = bounds.height - inset.top - inset.bottom
        let maxY = max(-inset.top, contentSize.height + inset.bottom - bounds.height)
        let target = min(maxY, contentOffset.y + visible * 0.9)
        guard target > contentOffset.y + 1 else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: true)
    }
}

extension UIView {
    /// The first scroll view in this view's subtree, itself included.
    func firstScrollView() -> UIScrollView? {
        if let scroll = self as? UIScrollView { return scroll }
        for sub in subviews { if let found = sub.firstScrollView() { return found } }
        return nil
    }
}

import CoreMotion

/// Turns the page when the reader nods while wearing AirPods (or other headphones with head tracking).
/// A nod is a quick tilt of the head away from where it has been resting and back again; slow changes of
/// posture just move the resting point.
@MainActor
final class HeadNodPager {
    private let manager = CMHeadphoneMotionManager()
    private var onNod: (() -> Void)?

    private enum Phase { case resting, leaving(since: TimeInterval), tilted(since: TimeInterval) }
    private var phase = Phase.resting
    private var baseline: Double?
    private var quietUntil: TimeInterval = 0

    /// How far the head must tilt (radians, ~11°), how close counts as back, and how quick it must be.
    private let tilt = 0.2, settle = 0.08, reach = 0.35, full = 1.0, cooldown = 1.2

    func start(onNod: @escaping () -> Void) {
        self.onNod = onNod
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            MainActor.assumeIsolated { self?.sample(pitch: motion.attitude.pitch, at: motion.timestamp) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        onNod = nil
        baseline = nil
        phase = .resting
    }

    private func sample(pitch: Double, at now: TimeInterval) {
        guard let base = baseline else { baseline = pitch; return }
        let off = abs(pitch - base)
        switch phase {
        case .resting:
            if off > settle, now >= quietUntil { phase = .leaving(since: now) }
            else { baseline = base * 0.95 + pitch * 0.05 }
        case .leaving(let since):
            if off > tilt { phase = .tilted(since: since) }
            else if now - since > reach || off < settle / 2 { rest(at: pitch) }
        case .tilted(let since):
            if off < settle {
                phase = .resting
                quietUntil = now + cooldown
                onNod?()
            } else if now - since > full {
                rest(at: pitch)
            }
        }
    }

    /// A slow or held movement: that is just a new posture.
    private func rest(at pitch: Double) {
        baseline = pitch
        phase = .resting
    }
}
#endif
