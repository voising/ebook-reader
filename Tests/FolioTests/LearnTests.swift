import SwiftUI
import XCTest
@testable import Folio

final class LearnTests: XCTestCase {
    // MARK: Spaced repetition

    func testGoodAnswersSpaceOut() {
        var card = Flashcard(front: "q", back: "a")
        XCTAssertTrue(card.isNew)
        XCTAssertTrue(card.isDue())
        var intervals: [Double] = []
        for _ in 0..<5 {
            card.apply(.good)
            intervals.append(card.interval)
        }
        XCTAssertEqual(intervals[0], 1)
        XCTAssertEqual(intervals[1], 3)
        XCTAssertEqual(intervals, intervals.sorted(), "each good answer should push the card further out")
        XCTAssertGreaterThan(intervals[4], 21)
        XCTAssertTrue(card.isMature)
        XCTAssertFalse(card.isDue())
    }

    func testAgainResetsAndComesBackSoon() {
        var card = Flashcard(front: "q", back: "a")
        card.apply(.good); card.apply(.good); card.apply(.good)
        let ease = card.ease
        card.apply(.again)
        XCTAssertEqual(card.lapses, 1)
        XCTAssertEqual(card.reps, 0)
        XCTAssertLessThan(card.ease, ease)
        XCTAssertLessThan(card.due.timeIntervalSinceNow, 11 * 60)
        XCTAssertGreaterThanOrEqual(card.ease, 1.3)
    }

    func testGradeLogsReview() {
        var data = LearnData(bookID: "b")
        let card = Flashcard(front: "q", back: "a")
        data.cards = [card]
        XCTAssertNotNil(data.grade(card.id, .easy))
        XCTAssertEqual(data.reviews?.count, 1)
        XCTAssertEqual(data.cards?.first?.interval, 4)
        XCTAssertNil(data.grade("missing", .good))
    }

    // MARK: Decoding

    func testLearnDataDecodesFromMinimalFile() throws {
        let data = try JSONDecoder().decode(LearnData.self, from: Data(#"{"bookID":"abc"}"#.utf8))
        XCTAssertEqual(data.bookID, "abc")
        XCTAssertNil(data.cards)
    }

    func testConceptMapAcceptsNumericIDsAndDropsDanglingEdges() throws {
        let json = #"{"title":"T","nodes":[{"id":1,"label":"A"},{"id":"2","label":"B","kind":"claim"}],"edges":[{"from":1,"to":"2","label":"causes"},{"from":1,"to":9},{"from":1,"to":1}]}"#
        let map = try JSONDecoder().decode(ConceptMap.self, from: Data(json.utf8)).cleaned
        XCTAssertEqual(map.nodes.map(\.id), ["1", "2"])
        XCTAssertEqual(map.edges?.count, 1)
        XCTAssertEqual(map.edges?.first?.label, "causes")
    }

    func testReadDistinguishesMissingFromUnreadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("missing.json")
        if case .missing = CloudStore.read(LearnData.self, at: missing) {} else { XCTFail("expected missing") }

        let garbage = dir.appendingPathComponent("garbage.json")
        try Data("{ not json".utf8).write(to: garbage)
        if case .unreadable = CloudStore.read(LearnData.self, at: garbage) {} else { XCTFail("expected unreadable") }

        let good = dir.appendingPathComponent("good.json")
        try Data(#"{"bookID":"abc"}"#.utf8).write(to: good)
        if case .value(let v) = CloudStore.read(LearnData.self, at: good) { XCTAssertEqual(v.bookID, "abc") } else { XCTFail("expected value") }

        // A highlights file written by the previous version still loads.
        let old = dir.appendingPathComponent("old.json")
        try Data(#"{"bookID":"abc","title":"T","author":"A","kind":"epub","highlights":[],"progress":0.5,"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8).write(to: old)
        if case .value(let v) = CloudStore.read(BookRecord.self, at: old) { XCTAssertEqual(v.progress, 0.5) } else { XCTFail("expected record") }
    }

    func testFullLearnDataSurvivesWriteAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("learn.json")

        var data = LearnData(bookID: "abc")
        data.title = "T"
        data.chat = StoredChat(messages: [StoredMessage(role: "user", text: "hi", quote: "q", isError: nil)], sessionID: "s", contextKey: "c0", mode: "socratic")
        data.maps = ["c0": ConceptMap(title: "M", nodes: [ConceptNode(id: "n1", label: "A", kind: "claim", summary: "s", quote: "q"), ConceptNode(id: "n2", label: "B")],
                                      edges: [ConceptEdge(from: "n1", to: "n2", label: "causes")], createdAt: Date())]
        data.primers = ["c0": Primer(overview: "o", questions: ["q1"], prerequisites: [], terms: [PrimerTerm(term: "t", meaning: "m")], createdAt: Date())]
        var card = Flashcard(front: "f", back: "b", quote: "q", sectionKey: "c0", sectionTitle: "S")
        data.cards = [card]
        data.attempts = [ExplainAttempt(id: "a", sectionKey: "c0", sectionTitle: "S", text: "t", score: 70, got: ["g"], missed: ["m"], misconceptions: [], feedback: "f", date: Date())]
        data.grade(card.id, .good)
        card = data.cards![0]

        CloudStore.write(data, to: url)
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard case .value(let back) = CloudStore.read(LearnData.self, at: url) else { return XCTFail("app-written learn file didn't read back") }
        XCTAssertEqual(back.cards?.first?.front, "f")
        XCTAssertEqual(back.cards?.first?.interval, 1)
        XCTAssertEqual(back.cards?.first?.due.timeIntervalSince1970 ?? 0, card.due.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(back.maps?["c0"]?.edges?.first?.label, "causes")
        XCTAssertEqual(back.maps?["c0"]?.nodes.count, 2)
        XCTAssertEqual(back.primers?["c0"]?.terms?.first?.term, "t")
        XCTAssertEqual(back.attempts?.first?.score, 70)
        XCTAssertEqual(back.reviews?.count, 1)
        XCTAssertEqual(back.chat?.mode, "socratic")
        XCTAssertEqual(back.chat?.messages?.first?.quote, "q")
    }

    // MARK: YouTube

    func testVideoIDParsing() {
        XCTAssertEqual(YouTube.videoID(from: "https://www.youtube.com/watch?v=aircAruvnKk&t=10s"), "aircAruvnKk")
        XCTAssertEqual(YouTube.videoID(from: " https://youtu.be/aircAruvnKk?si=x "), "aircAruvnKk")
        XCTAssertEqual(YouTube.videoID(from: "https://www.youtube.com/shorts/aircAruvnKk"), "aircAruvnKk")
        XCTAssertEqual(YouTube.videoID(from: "https://m.youtube.com/live/aircAruvnKk"), "aircAruvnKk")
        XCTAssertEqual(YouTube.videoID(from: "aircAruvnKk"), "aircAruvnKk")
        XCTAssertNil(YouTube.videoID(from: "https://example.com/watch?v=aircAruvnKk"))
        XCTAssertNil(YouTube.videoID(from: "hello"))
        XCTAssertEqual(YouTube.timestamp(in: URL(string: "https://www.youtube.com/watch?v=aircAruvnKk&t=123s")!), 123)
        XCTAssertNil(YouTube.timestamp(in: URL(string: "https://example.com/?t=5")!))
    }

    func testTranscriptParsingAndParagraphs() {
        let events = (0..<200).map { i in
            #"{"tStartMs":\#(i * 3000),"dDurationMs":3000,"segs":[{"utf8":"word\#(i) and some more words here\#(i % 7 == 6 ? "." : "")"}]}"#
        } + [#"{"tStartMs":5,"aAppend":1,"segs":[{"utf8":"\n"}]}"#, #"{"tStartMs":0,"id":1}"#]
        let segments = YouTube.parseJSON3(Data(#"{"events":[\#(events.joined(separator: ","))]}"#.utf8))
        XCTAssertEqual(segments.count, 200, "newline-only and seg-less events are skipped")
        let paragraphs = YouTube.paragraphs(segments)
        XCTAssertGreaterThan(paragraphs.count, 5)
        XCTAssertEqual(paragraphs.first?.start, 0)
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: " "), segments.map(\.text).joined(separator: " "), "no text lost")
        XCTAssertTrue(paragraphs.allSatisfy { $0.text.split(separator: " ").count <= 140 })
        XCTAssertEqual(YouTube.clock(3725), "1:02:05")
        XCTAssertEqual(YouTube.clock(65), "1:05")
    }

    // MARK: Graph

    func testLayoutIsDeterministicAndSpread() {
        let ids = (0..<14).map { "n\($0)" }
        let edges = (1..<14).map { ("n\(($0 - 1) / 2)", "n\($0)") }
        let a = GraphLayout.compute(ids: ids, edges: edges, aspect: 1.6)
        let b = GraphLayout.compute(ids: ids, edges: edges, aspect: 1.6)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 14)
        for p in a.values {
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y))
        }
        var closest = Double.greatestFiniteMagnitude
        for i in ids { for j in ids where i < j {
            closest = min(closest, hypot(Double(a[i]!.x - a[j]!.x), Double(a[i]!.y - a[j]!.y)))
        } }
        XCTAssertGreaterThan(closest, 0.06, "no two nodes on top of each other")
    }

    /// Renders the concept map off-screen. Set FOLIO_SNAPSHOT_DIR to keep the PNG.
    @MainActor func testGraphSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] else { throw XCTSkip("set FOLIO_SNAPSHOT_DIR") }
        let json = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("map.json"))
        let map = try JSONDecoder().decode(ConceptMap.self, from: json).cleaned
        let view = GraphView(nodes: map.nodes.map { GraphNode(id: $0.id, label: $0.label, color: .conceptKind($0.kind)) },
                             edges: (map.edges ?? []).map { GraphEdge(from: $0.from, to: $0.to, label: $0.label) },
                             selection: .constant(map.nodes.first?.id))
            .frame(width: 1000, height: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1000, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.png"))
    }

    // MARK: Live (calls the Claude CLI; set FOLIO_LIVE=1)

    private static let sample = StudySection(key: "c0", title: "What is a neuron?", text: """
    A neural network is built from neurons. For now, think of a neuron as a thing that holds a number between 0 and 1. \
    The network starts with 784 neurons, one for each of the 28 by 28 pixels of the input image; each holds the \
    grayscale value of its pixel, called its activation. These 784 neurons make up the first layer. The last layer \
    has 10 neurons, one per digit, and the activation of each represents how much the system thinks the image \
    corresponds to that digit. In between sit hidden layers. Activations in one layer determine the activations of \
    the next: each neuron in the second layer takes a weighted sum of all first-layer activations. The weights say \
    which pixels matter to that neuron. A bias is added to the weighted sum, to say how high the sum must be before \
    the neuron becomes meaningfully active. The result is squished into the range 0 to 1 by the sigmoid function, so \
    very negative inputs end up near 0 and very positive inputs near 1. The hope is that the second layer picks up \
    on edges, the third on patterns such as loops and lines, and the last on digits. Learning means finding the \
    right weights and biases: about 13,000 numbers in total that can be tweaked to make the network behave differently.
    """)

    @MainActor func testLiveMapCardsAndGrading() async throws {
        guard ProcessInfo.processInfo.environment["FOLIO_LIVE"] != nil else { throw XCTSkip("set FOLIO_LIVE=1") }
        let s = Self.sample
        let map = try await ClaudeOnce.json(ConceptMap.self, system: StudyPrompts.mapSystem,
                                            prompt: StudyPrompts.map(book: "Neural networks", author: "", section: s)).cleaned
        XCTAssertGreaterThanOrEqual(map.nodes.count, 6)
        XCTAssertGreaterThanOrEqual(map.edges?.count ?? 0, 5)
        let quoted = map.nodes.compactMap(\.quote).filter { s.text.localizedCaseInsensitiveContains($0) }
        XCTAssertGreaterThan(quoted.count, map.nodes.count / 2, "most quotes should be findable in the text")
        if let dir = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT_DIR"] {
            try JSONEncoder().encode(map).write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.json"))
        }

        let cards = try await ClaudeOnce.json(CardsDTO.self, system: StudyPrompts.cardsSystem,
                                              prompt: StudyPrompts.cards(book: "Neural networks", author: "", section: s,
                                                                         highlights: ["A bias is added to the weighted sum"], existing: [], count: 4))
        XCTAssertEqual(cards.cards.count, 4)

        let graded = try await ClaudeOnce.json(ExplainDTO.self, system: StudyPrompts.explainSystem,
                                               prompt: StudyPrompts.explain(book: "Neural networks", author: "", section: s,
                                                                            explanation: "Neurons hold numbers. The first layer is the pixels and the last layer has 10 outputs for digits. The network has exactly 100 weights."))
        let score = try XCTUnwrap(graded.score)
        XCTAssertTrue((5...75).contains(score), "partial, partly wrong explanation scored \(score)")
        XCTAssertFalse((graded.missed ?? []).isEmpty)
        XCTAssertFalse((graded.misconceptions ?? []).isEmpty)

        let primer = try await ClaudeOnce.json(Primer.self, system: StudyPrompts.primerSystem,
                                               prompt: StudyPrompts.primer(book: "Neural networks", author: "", section: s, earlier: ["Introduction"]))
        XCTAssertGreaterThanOrEqual(primer.questions?.count ?? 0, 3)
    }
}
