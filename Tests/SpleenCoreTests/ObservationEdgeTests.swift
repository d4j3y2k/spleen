import XCTest
@testable import SpleenCore

final class ObservationEdgeTests: XCTestCase {
    private let a = "01234567-89ab-cdef-0123-456789abcdef", b = "11234567-89ab-cdef-0123-456789abcdef"

    func testOnlyKnownClaudePagesCountAsNoConversation() {
        for page in ["https://claude.ai/new", "https://claude.ai/projects", "claude.ai/recents", "https://claude.ai/settings/profile"] {
            XCTAssertTrue(ClaudeDesktopObservation.isOtherClaudePage(url: page), page)
        }
        for unknown in ["https://claude.ai/chat/\(a)", "https://claude.ai/chat/not-a-uuid", "https://claude.ai/epitaxy/remote_\(a)",
                        "https://example.com/new", "about:blank", ""] {
            XCTAssertFalse(ClaudeDesktopObservation.isOtherClaudePage(url: unknown), unknown)
        }
    }

    func testClaudeRendererPageIsNeitherAConversationNorALeftPage() {
        // Claude Desktop 5.1231 shows its own renderer page beside the conversation's web area.
        // It must not count as a conversation, nor as leaving one.
        let renderer = "file:///Applications/Claude.app/Contents/Resources/app.asar/.vite/renderer/main_window/index.html"
        XCTAssertNil(ClaudeDesktopObservation(url: renderer, title: ""))
        XCTAssertFalse(ClaudeDesktopObservation.isOtherClaudePage(url: renderer))
        // In that build the conversation's web area sits nine levels below the focused window.
        XCTAssertGreaterThanOrEqual(ClaudeDesktopObservation.webAreaSearchDepth, 9)
    }

    func testBareAppNameIsNotATitle() throws {
        XCTAssertEqual(try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(a)", title: "Claude")).title, "")
        XCTAssertEqual(try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/epitaxy/local_\(a)", title: "Claude Code")).title, "")
        XCTAssertEqual(try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(a)", title: "Claude notes - Claude")).title, "Claude notes")
        XCTAssertEqual(try XCTUnwrap(CodexDesktopObservation(url: "app://-/local/\(a)", title: "Codex")).title, "")
        XCTAssertEqual(try XCTUnwrap(CodexDesktopObservation(url: "app://-/local/\(a)", title: "Codex review - Codex")).title, "Codex review")
    }

    func testClaudeDwellTimerFromAnEarlierVisitCannotCommitAReturn() throws {
        let gate = ClaudeDesktopObservationGate()
        let first = try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(a)", title: "A"))
        let second = try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(b)", title: "B"))
        func read(_ observation: ClaudeDesktopObservation) throws -> ClaudeDesktopObservationGate.Ticket {
            let ticket = try XCTUnwrap(gate.requestRead()); XCTAssertTrue(gate.beginRead(ticket))
            XCTAssertTrue(gate.acceptDelivery(observation, for: ticket)); return ticket
        }
        // A, then B, then A again, all within one dwell.
        let earlier = try read(first), passed = try read(second), returned = try read(first)
        XCTAssertNil(gate.commitDwell(first, for: earlier), "the first visit's timer would commit after only part of the return's dwell")
        XCTAssertNil(gate.commitDwell(second, for: passed))
        XCTAssertEqual(gate.commitDwell(first, for: returned)?.key, first.key)
    }

    func testCodexDwellTimerFromAnEarlierVisitCannotCommitAReturn() throws {
        let gate = CodexDesktopObservationGate()
        let first = try XCTUnwrap(CodexDesktopObservation(url: "app://-/local/\(a)", title: "A"))
        let second = try XCTUnwrap(CodexDesktopObservation(url: "app://-/local/\(b)", title: "B"))
        func read(_ observation: CodexDesktopObservation) throws -> CodexDesktopObservationGate.Ticket {
            let ticket = try XCTUnwrap(gate.requestRead()); XCTAssertTrue(gate.beginRead(ticket))
            XCTAssertTrue(gate.acceptDelivery(observation, for: ticket)); return ticket
        }
        let earlier = try read(first), _ = try read(second), returned = try read(first)
        XCTAssertNil(gate.commitDwell(first, for: earlier))
        XCTAssertEqual(gate.commitDwell(first, for: returned)?.key, first.key)
    }

    func testLeavingForAPageThatIsNotAConversationMakesTheReturnAnArrival() throws {
        let gate = ClaudeDesktopObservationGate()
        let chat = try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(a)", title: "A"))
        let arrived = try XCTUnwrap(gate.requestRead()); XCTAssertTrue(gate.beginRead(arrived))
        XCTAssertTrue(gate.acceptDelivery(chat, for: arrived))
        let left = try XCTUnwrap(gate.requestRead()); XCTAssertTrue(gate.beginRead(left))
        XCTAssertTrue(gate.clearDelivery(for: left))
        XCTAssertNil(gate.commitDwell(chat, for: arrived), "leaving cancels the pending visit")
        let back = try XCTUnwrap(gate.requestRead()); XCTAssertTrue(gate.beginRead(back))
        XCTAssertTrue(gate.acceptDelivery(chat, for: back), "returning is a new arrival")
        XCTAssertFalse(gate.clearDelivery(for: left), "an older read cannot clear a newer delivery")
    }

    func testNoConversationPageMakesTheChatJustLeftTheReturnTarget() {
        let chat = ConversationKey(provider: .claude, id: a), now = Date()
        let left = ContextMemory.resolveCurrent(recorded: chat, recordedAt: now.addingTimeInterval(-60), previous: nil,
                                                foreground: nil, front: .providerWithoutConversation(.claude), at: now)
        XCTAssertNil(left.current)
        XCTAssertEqual(left.previous, chat)
        let inside = ContextMemory.resolveCurrent(recorded: chat, recordedAt: now.addingTimeInterval(-60), previous: nil,
                                                  foreground: nil, front: .provider(.claude), at: now)
        XCTAssertEqual(inside.current, chat)
    }

    func testNullOrScalarResultIsAProtocolErrorNotACrash() throws {
        func line(_ text: String) -> Data { Data(text.utf8) }
        XCTAssertNil(try CodexCatalogClient.responseResult(line(#"{"id":2,"result":{}}"#), id: 1), "another request's reply is skipped")
        XCTAssertNotNil(try CodexCatalogClient.responseResult(line(#"{"id":1,"result":{"data":[]}}"#), id: 1))
        for bad in [#"{"id":1,"result":null}"#, #"{"id":1,"result":3}"#, #"{"id":1,"result":"text"}"#,
                    #"{"id":1,"error":{"code":1}}"#, #"[1]"#] {
            XCTAssertThrowsError(try CodexCatalogClient.responseResult(line(bad), id: 1), bad)
        }
    }

    func testDataFilesAndTheirFolderAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-private-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func mode(_ url: URL) throws -> Int { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue }
        let file = root.appendingPathComponent("nested/relevance.json")
        try PrivateFile.write(Data("{}".utf8), to: file)
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(file.deletingLastPathComponent()), 0o700)
        let earlier = root.appendingPathComponent("earlier")
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateFile.restrict(earlier)
        XCTAssertEqual(try mode(earlier), 0o700, "a folder created world-readable by an earlier build is tightened")
    }
}
