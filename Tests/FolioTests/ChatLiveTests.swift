import XCTest
@testable import Folio

/// These call the Claude CLI. Set FOLIO_LIVE=1 to run them.
final class ChatLiveTests: XCTestCase {
    @MainActor private func finish(_ chat: ChatModel, timeout: TimeInterval = 240) async throws -> ChatModel.Message {
        let deadline = Date().addingTimeInterval(timeout)
        while chat.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertFalse(chat.isRunning, "timed out")
        return try XCTUnwrap(chat.messages.last)
    }

    @MainActor func testBookChatSurvivesRestore() async throws {
        guard ProcessInfo.processInfo.environment["FOLIO_LIVE"] != nil else { throw XCTSkip("set FOLIO_LIVE=1") }
        let context = ChapterContext(key: "c0", title: "Biases", text: "A bias is added to the weighted sum to say how high the sum must be before the neuron becomes meaningfully active. The codeword for this section is PERSIMMON.")
        let first = ChatModel(scope: .book(title: "Test", author: ""))
        first.contextProvider = { context }
        var saved: StoredChat?
        first.onPersist = { saved = $0 }
        first.mode = .simple
        first.send("What is the codeword? Reply with just the word.")
        let reply = try await finish(first)
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.uppercased().contains("PERSIMMON"), reply.text)

        // A new model restored from disk continues the same CLI session without resending the section.
        let stored = try XCTUnwrap(saved)
        XCTAssertNotNil(stored.sessionID)
        XCTAssertEqual(stored.mode, "simple")
        let second = ChatModel(scope: .book(title: "Test", author: ""))
        second.contextProvider = { context }
        second.restore(stored)
        XCTAssertEqual(second.messages.count, 3)
        second.send("Spell that codeword backwards. Reply with just the letters.")
        let again = try await finish(second)
        XCTAssertFalse(again.isError, again.text)
        XCTAssertTrue(again.text.uppercased().contains("NOMMISREP"), again.text)
        XCTAssertEqual(second.messages.filter { $0.role == .note }.count, 1, "section isn't announced twice")

        // A saved session that no longer exists is replaced transparently.
        var broken = stored
        broken.sessionID = "00000000-0000-4000-8000-000000000000"
        let third = ChatModel(scope: .book(title: "Test", author: ""))
        third.contextProvider = { context }
        third.restore(broken)
        third.send("What is the codeword? Reply with just the word.")
        let recovered = try await finish(third)
        XCTAssertFalse(recovered.isError, recovered.text)
        XCTAssertTrue(recovered.text.uppercased().contains("PERSIMMON"), recovered.text)
    }

    @MainActor func testLibraryChatSearchesFiles() async throws {
        guard ProcessInfo.processInfo.environment["FOLIO_LIVE"] != nil else { throw XCTSkip("set FOLIO_LIVE=1") }
        let dir = LibraryIndex.root.appendingPathComponent("Folio Test Source [test00]", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "The quokka principle states that every lighthouse keeper must own exactly three kettles.".write(
            to: dir.appendingPathComponent("001 Kettles.txt"), atomically: true, encoding: .utf8)
        let chat = ChatModel(scope: .library)
        chat.send("According to my library, what does the quokka principle state, and which source is it in?")
        let reply = try await finish(chat)
        print("library reply:", reply.text)
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.localizedCaseInsensitiveContains("three kettles"), reply.text)
        XCTAssertTrue(reply.text.contains("Folio Test Source"), reply.text)
        XCTAssertFalse(reply.text.contains("\u{200B}"))
    }
}
