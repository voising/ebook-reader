import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    let reader: ReaderModel
    let document: PDFDocument
    let theme: ThemeSnapshot

    func makeNSView(context: Context) -> FolioPDFView {
        let view = FolioPDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = theme.theme.background
        view.reader = reader
        reader.pdfView = view
        view.reinstallAnnotations(reader.highlights)
        let start = reader.pageIndex
        DispatchQueue.main.async {
            if let page = document.page(at: start) { view.go(to: page) }
            view.startTrackingPages()
        }
        return view
    }

    func updateNSView(_ view: FolioPDFView, context: Context) {
        if view.backgroundColor != theme.theme.background {
            view.backgroundColor = theme.theme.background
        }
    }
}

final class FolioPDFView: PDFView {
    weak var reader: ReaderModel?
    private var bar: NSHostingView<SelectionBar>?
    private var pendingShow: DispatchWorkItem?
    private var activeHighlightID: String?
    private static let prefix = "folio:"

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func startTrackingPages() {
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: self)
        pageChanged()
    }

    @objc private func pageChanged() {
        guard let doc = document, let page = currentPage else { return }
        reader?.updatePage(doc.index(for: page))
    }

    // MARK: Annotations

    func reinstallAnnotations(_ highlights: [Highlight]) {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where (a.userName ?? "").hasPrefix(Self.prefix) { page.removeAnnotation(a) }
        }
        highlights.forEach(addAnnotations)
    }

    func addAnnotations(for h: Highlight) {
        guard let doc = document else { return }
        for r in h.rects ?? [] {
            guard let page = doc.page(at: r.page) else { continue }
            let a = PDFAnnotation(bounds: r.cgRect, forType: .highlight, withProperties: nil)
            a.color = h.color.nsColor.withAlphaComponent(0.42)
            a.userName = Self.prefix + h.id
            page.addAnnotation(a)
        }
    }

    func removeAnnotations(for id: String) {
        guard let doc = document else { return }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.userName == Self.prefix + id { page.removeAnnotation(a) }
        }
    }

    func flash(_ id: String) {
        guard let doc = document else { return }
        var anns: [PDFAnnotation] = []
        for i in 0..<doc.pageCount {
            anns += doc.page(at: i)?.annotations.filter { $0.userName == Self.prefix + id } ?? []
        }
        let original = anns.first?.color
        anns.forEach { $0.color = ($0.color.withAlphaComponent(0.85)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            anns.forEach { if let original { $0.color = original } }
        }
    }

    // MARK: Selection → highlight

    func highlightSelection(_ color: HighlightColor) {
        guard let sel = currentSelection, let doc = document,
              let text = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        var rects: [PageRect] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                if b.width > 0.5, b.height > 0.5 { rects.append(PageRect(page: doc.index(for: page), rect: b)) }
            }
        }
        guard !rects.isEmpty else { return }
        reader?.addPDFHighlight(text: text, rects: rects, color: color)
        clearSelection()
        hideBar()
    }

    func askAboutSelection() {
        guard let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        reader?.ask(about: text)
        hideBar()
    }

    @objc private func selectionChanged() {
        pendingShow?.cancel()
        guard currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            if activeHighlightID == nil { hideBar() }
            return
        }
        scheduleSelectionBar()
    }

    private func scheduleSelectionBar() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleSelectionBar(); return }
            guard let sel = self.currentSelection, let page = sel.pages.first else { return }
            var rect = self.convert(sel.bounds(for: page), from: page)
            if let last = sel.pages.last, last != page { rect = rect.union(self.convert(sel.bounds(for: last), from: last)) }
            self.activeHighlightID = nil
            self.showBar(above: rect, active: nil)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func showBar(above rect: NSRect, active: HighlightColor?) {
        hideBar()
        let isMark = activeHighlightID != nil
        let view = NSHostingView(rootView: SelectionBar(
            activeColor: active,
            isExisting: isMark,
            onColor: { [weak self] c in
                guard let self else { return }
                if let id = self.activeHighlightID { self.reader?.recolor(id, to: c); self.hideBar() } else { self.highlightSelection(c) }
            },
            onAsk: { [weak self] in
                guard let self else { return }
                if let id = self.activeHighlightID, let h = self.reader?.highlights.first(where: { $0.id == id }) {
                    self.reader?.ask(about: h.text); self.hideBar()
                } else { self.askAboutSelection() }
            },
            onSecondary: { [weak self] in
                guard let self else { return }
                if let id = self.activeHighlightID {
                    self.reader?.removeHighlight(id)
                } else if let s = self.currentSelection?.string {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                }
                self.hideBar()
            }
        ))
        let size = view.fittingSize
        var origin = NSPoint(x: rect.midX - size.width / 2, y: isFlipped ? rect.minY - size.height - 10 : rect.maxY + 10)
        let outOfTop = isFlipped ? origin.y < 4 : origin.y + size.height > bounds.height - 4
        if outOfTop { origin.y = isFlipped ? rect.maxY + 10 : rect.minY - size.height - 10 }
        origin.x = max(8, min(origin.x, bounds.width - size.width - 8))
        view.frame = NSRect(origin: origin, size: size)
        view.alphaValue = 0
        addSubview(view)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; view.animator().alphaValue = 1 }
        bar = view
    }

    func hideBar() {
        bar?.removeFromSuperview()
        bar = nil
    }

    override func mouseDown(with event: NSEvent) {
        hideBar()
        activeHighlightID = nil
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false) {
            let p = convert(point, to: page)
            if let hit = page.annotations.first(where: { ($0.userName ?? "").hasPrefix(Self.prefix) && $0.bounds.contains(p) }),
               let id = hit.userName?.dropFirst(Self.prefix.count) {
                activeHighlightID = String(id)
                clearSelection()
                let color = reader?.highlights.first { $0.id == String(id) }?.color
                showBar(above: convert(hit.bounds, from: page), active: color)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if bar != nil { hideBar(); activeHighlightID = nil }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard currentSelection?.string?.isEmpty == false else { return menu }
        let ask = NSMenuItem(title: "Ask Claude About Selection", action: #selector(menuAsk), keyEquivalent: "")
        ask.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(ask, at: 0)
        for color in HighlightColor.allCases.reversed() {
            let item = NSMenuItem(title: "Highlight \(color.label)", action: #selector(menuHighlight(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color.rawValue
            item.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [color.nsColor]))
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func menuHighlight(_ item: NSMenuItem) {
        highlightSelection(HighlightColor(rawValue: item.representedObject as? String ?? "") ?? .yellow)
    }

    @objc private func menuAsk() { askAboutSelection() }
}

struct SelectionBar: View {
    var activeColor: HighlightColor?
    var isExisting: Bool
    var onColor: (HighlightColor) -> Void
    var onAsk: () -> Void
    var onSecondary: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            ForEach(HighlightColor.allCases) { c in
                Button { onColor(c) } label: {
                    Circle().fill(c.color).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white.opacity(activeColor == c ? 1 : 0.18), lineWidth: activeColor == c ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help("Highlight \(c.label)")
            }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 16).padding(.horizontal, 2)
            Button(action: onAsk) { Label("Ask Claude", systemImage: "sparkle").labelStyle(.titleAndIcon) }
                .buttonStyle(BarButtonStyle())
            Button(isExisting ? "Remove" : "Copy", action: onSecondary)
                .buttonStyle(BarButtonStyle(tint: isExisting ? Color(red: 1, green: 0.54, blue: 0.5) : .white))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .padding(14)
        .environment(\.colorScheme, .dark)
    }
}

struct BarButtonStyle: ButtonStyle {
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tint.opacity(0.92))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(configuration.isPressed ? 0.18 : 0.0001)))
            .contentShape(Rectangle())
    }
}
