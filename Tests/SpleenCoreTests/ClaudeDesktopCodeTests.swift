import XCTest
@testable import SpleenCore

final class ClaudeDesktopCodeTests: XCTestCase {
    private let uuid = "01234567-89ab-cdef-0123-456789abcdef"
    private var identity: String { "desktop-code:local_" + uuid }
    private var link: String { "claude://claude.ai/epitaxy/local_" + uuid }

    func testExactDesktopRouteAndObservationHaveOneCanonicalIdentity() throws {
        let target = try ClaudeDesktopCodeTarget(" \nclaude://claude.ai/epitaxy/local_\(uuid.uppercased())\t")
        let observation = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/epitaxy/local_" + uuid, title: "Work - Claude Code"))
        XCTAssertEqual(target.id, identity)
        XCTAssertEqual(target.key, observation.key)
        XCTAssertEqual(target.url.absoluteString, link)
        XCTAssertEqual(try ClaudeDesktopCodeTarget(target.url.absoluteString), target)
        XCTAssertEqual(try ClaudeDesktopCodeTarget(conversationID: observation.key.id), target)
        XCTAssertEqual(Set([target, try ClaudeDesktopCodeTarget(link)]).count, 1)
        XCTAssertNotEqual(target.key, ConversationKey(provider: .claude, id: uuid))
    }

    func testRejectsOtherSurfacesAndAmbiguousAuthorities() {
        let path = "/epitaxy/local_" + uuid
        assertInvalid([
            "", uuid, identity, "local_" + uuid, "claude.ai" + path,
            "https://claude.ai" + path, "http://claude.ai" + path,
            "claude://claude.ai/chat/" + uuid, "claude://code/" + uuid,
            "claude://code/new", "claude://claude.ai/epitaxy/" + uuid,
            "claude://claude.ai/epitaxy/session_" + uuid,
            "claude://example.com" + path, "claude://claude.ai.example.com" + path,
            "claude://www.claude.ai" + path, "claude://claude.ai." + path,
            "claude://user@claude.ai" + path, "claude://user:pass@claude.ai" + path,
            "claude://claude.ai:443" + path, "CLAUDE://claude.ai" + path,
            "claude://CLAUDE.AI" + path, "claude://claude.ai/Epitaxy/local_" + uuid
        ])
        XCTAssertThrowsError(try ClaudeChatTarget(link))
    }

    func testRejectsParametersEncodingNormalizationAndNonUUIDs() {
        let prefix = "claude://claude.ai/epitaxy/local_"
        assertInvalid([
            link + "?", link + "?prompt=hello", link + "#", link + "#section",
            link + "/", link + "/more", link + ";parameters", link + "\u{0000}",
            prefix + "../" + uuid, prefix + "./" + uuid, prefix + "/" + uuid,
            prefix + "%30" + uuid.dropFirst(), link + "%2F",
            prefix + uuid.prefix(8) + "\n" + uuid.dropFirst(8),
            "claude://claude.ai/%65pitaxy/local_" + uuid,
            "claude://claude.ai/epitaxy/%6cocal_" + uuid,
            "claude://claude.ai\\epitaxy\\local_" + uuid,
            prefix, prefix + "new", prefix + "{" + uuid + "}",
            prefix + uuid.replacingOccurrences(of: "-", with: ""),
            prefix + uuid.replacingOccurrences(of: "-", with: "_"),
            prefix + uuid.dropLast(), prefix + uuid + "0", prefix + "g" + uuid.dropFirst(),
            prefix + uuid.replacingOccurrences(of: "0", with: "０")
        ])
    }

    func testIdentityInitializerNeverJoinsBareOrEngineIDs() throws {
        for raw in [uuid, "local_" + uuid, "desktop-code:" + uuid,
                    "desktop-code:session_" + uuid, link, " " + identity,
                    identity + " ", identity + "?", identity + "/",
                    "Desktop-Code:local_" + uuid] {
            XCTAssertThrowsError(try ClaudeDesktopCodeTarget(conversationID: raw), raw)
        }
        XCTAssertEqual(try ClaudeDesktopCodeTarget(conversationID: "desktop-code:local_" + uuid.uppercased()).id, identity)
    }

    func testCodeChatAndCodexWithSameUUIDAndTitlePersistSeparately() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: "Same title", link: "codex://threads/" + uuid, pinned: true)
        let legacy = state.destinations[0]
        try state.upsert(id: nil, title: "Same title", link: "https://claude.ai/chat/" + uuid, pinned: false)
        try state.upsert(id: nil, title: "Same title", link: link, pinned: false)
        XCTAssertEqual(state.version, 3)
        XCTAssertEqual(state.destinations[0], legacy)
        XCTAssertEqual(Set(state.destinations.map(\.conversationKey)).count, 3)
        XCTAssertEqual(try state.destinations.map { try $0.navigationURL.absoluteString },
                       ["codex://threads/" + uuid, "claude://claude.ai/chat/" + uuid, link])
        XCTAssertEqual(state.destinations[2].conversationKey, try ClaudeDesktopCodeTarget(link).key)
        XCTAssertThrowsError(try state.upsert(id: nil, title: "Renamed duplicate", link: link, pinned: false))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = StateRepository(url: directory.appendingPathComponent("state.json"))
        try repository.save(state)
        XCTAssertEqual(try repository.load(), state)
    }

    func testSchemaNeverDowngradesAfterCodeTargetOrOrdinaryChatEdit() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: "Code", link: link, pinned: false)
        let codeID = try XCTUnwrap(state.destinations.first?.id)
        state.recordDispatch(codeID, at: Date(timeIntervalSince1970: 100))
        try state.upsert(id: nil, title: "Chat", link: "claude://claude.ai/chat/" + uuid, pinned: false)
        XCTAssertEqual(state.version, 3)
        try state.upsert(id: codeID, title: "Renamed Code", link: link, pinned: true)
        XCTAssertEqual(state.destinations[0].lastOpenedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(state.version, 3)
        try state.validate()
        state.remove(codeID)
        XCTAssertEqual(state.version, 3)
        try state.validate()
    }

    func testRejectsCodeInOlderSchemaAndNoncanonicalStoredIdentities() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: "Code", link: link, pinned: false)
        for oldVersion in [1, 2] {
            var old = state; old.version = oldVersion
            XCTAssertThrowsError(try old.validate())
        }
        for invalid in ["local_" + uuid, "desktop-code:local_" + uuid.uppercased(), identity + " ", identity + "?", "desktop-code:" + uuid] {
            var malformed = state; malformed.destinations[0].threadID = invalid
            XCTAssertThrowsError(try malformed.validate(), invalid)
        }
        var future = state; future.version = 4
        XCTAssertThrowsError(try future.validate())
    }

    private func assertInvalid(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            XCTAssertThrowsError(try ClaudeDesktopCodeTarget(input), input, file: file, line: line) { error in
                XCTAssertEqual(error as? ClaudeDesktopCodeTargetError, .invalidSessionLink, file: file, line: line)
            }
        }
    }
}
