import AppKit
import PDFKit
import XCTest
@testable import Folio

/// Drives the PDF view with synthetic mouse events in a window parked far off-screen.
@MainActor
final class PDFSelectionTests: XCTestCase {
    private var window: NSWindow!
    private var view: FolioPDFView!

    override func setUp() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 700))
        text.font = .systemFont(ofSize: 18)
        text.string = String(repeating: "Alice was beginning to get very tired of sitting by her sister on the bank. ", count: 12)
        let document = try XCTUnwrap(PDFDocument(data: text.dataWithPDF(inside: text.bounds)))
        window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        view = FolioPDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        window.contentView = view
        window.orderBack(nil)
        pump(0.5)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        view = nil
    }

    private func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The middle of a character on the first page, in window coordinates.
    private func point(ofCharacter index: Int) throws -> NSPoint {
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let box = view.convert(page.characterBounds(at: index), from: page)
        return view.convert(NSPoint(x: box.midX, y: box.midY), to: nil)
    }

    /// A drag where the pointer rests before the button comes up. While it rests, PDFKit reports the
    /// selection on timer ticks, which once made Folio think the selection had not come from the mouse.
    func testDragWithAPauseBeforeReleaseIsTreatedAsAMouseSelection() throws {
        let start = try point(ofCharacter: 6), end = try point(ofCharacter: 60)
        DispatchQueue.global().async {
            for step in 1...6 {
                let t = CGFloat(step) / 6
                NSApp.postEvent(self.event(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)), atStart: false)
                Thread.sleep(forTimeInterval: 0.04)
            }
            Thread.sleep(forTimeInterval: 0.9) // the pause
            NSApp.postEvent(self.event(.leftMouseUp, end), atStart: false)
        }
        view.mouseDown(with: event(.leftMouseDown, start))
        XCTAssertGreaterThan((view.currentSelection?.string ?? "").split(separator: " ").count, 1, "the drag selected several words")
        pump(0.6)
        // The mouse path turns the selection into a highlight and clears it; the other path leaves it selected.
        XCTAssertTrue((view.currentSelection?.string ?? "").isEmpty, "a mouse selection is taken as a highlight")
    }

    /// A selection set from elsewhere (a search result, Select All) must stay a selection.
    func testSelectionSetInCodeIsNotHighlighted() throws {
        let page = try XCTUnwrap(view.document?.page(at: 0))
        view.setCurrentSelection(page.selection(for: NSRange(location: 0, length: 40)), animate: false)
        pump(0.6)
        XCTAssertFalse((view.currentSelection?.string ?? "").isEmpty)
    }
}
