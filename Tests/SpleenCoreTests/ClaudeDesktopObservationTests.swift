import XCTest
@testable import SpleenCore

final class ClaudeDesktopObservationTests: XCTestCase {
    private let id = "01234567-89ab-cdef-0123-456789abcdef"

    func testKnownAXFormsAndProviderSeparatedIdentity() throws {
        let chat = try XCTUnwrap(ClaudeDesktopObservation(url: "https://claude.ai/chat/\(id)", title: "Notes - Claude"))
        let code = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/epitaxy/local_\(id.uppercased())", title: "Editor - Claude Code"))
        XCTAssertEqual(chat.surface, .chat)
        XCTAssertEqual(chat.id, id)
        XCTAssertEqual(chat.title, "Notes")
        XCTAssertEqual(chat.key, ConversationKey(provider: .claude, id: id))
        XCTAssertEqual(code.surface, .code)
        XCTAssertEqual(code.id, "local_" + id)
        XCTAssertEqual(code.key.id, "desktop-code:local_" + id)
        XCTAssertEqual(code.title, "Editor")
        XCTAssertNotEqual(chat.key, code.key)
        XCTAssertEqual(ClaudeDesktopObservation(url: "https://claude.ai/epitaxy/local_\(id)", title: "Editor"), code)
        XCTAssertEqual(ClaudeDesktopObservation(url: "claude.ai/chat/\(id)", title: "Notes"), chat)
    }

    func testTitlesAreBoundedAndControlCharactersRemoved() throws {
        let value = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/chat/\(id)", title: String(repeating: "猫", count: 250)))
        XCTAssertEqual(value.title.count, 180)
        XCTAssertEqual(ClaudeDesktopObservation(url: "claude.ai/chat/\(id)", title: " \nOne\tTwo\u{0000} \n")?.title, "One Two")
        XCTAssertEqual(ClaudeDesktopObservation(url: "claude.ai/chat/\(id)", title: "")?.title, "")
    }

    func testRejectsUnknownSchemesHostsAndRoutes() {
        for raw in ["codex://threads/\(id)", "claude://claude.ai/chat/\(id)", "http://claude.ai/chat/\(id)",
                    "https://claude.ai.evil/chat/\(id)", "https://user@claude.ai/chat/\(id)",
                    "https://claude.ai:443/chat/\(id)", "//claude.ai/chat/\(id)",
                    "https://claude.ai/new", "https://claude.ai/project/\(id)",
                    "https://claude.ai/epitaxy/\(id)", "https://claude.ai/epitaxy/session_123",
                    "https://claude.ai/chat/local_\(id)", " https://claude.ai/chat/\(id)",
                    "https://CLAUDE.AI/chat/\(id)", "https://claude.ai/%63hat/\(id)"] {
            XCTAssertNil(ClaudeDesktopObservation(url: raw, title: "Ignored"), raw)
        }
    }

    func testRejectsQueryFragmentEncodingAndPathNormalization() {
        for prefix in ["https://claude.ai/chat/", "claude.ai/epitaxy/local_"] {
            for tail in ["new", id + "?", id + "?x=y", id + "#", id + "/", id + "/more",
                         "../" + id, "./" + id, "%30" + id.dropFirst(), id + "\n",
                         "{" + id + "}", id.replacingOccurrences(of: "-", with: ""), id + "\u{0000}"] {
                XCTAssertNil(ClaudeDesktopObservation(url: prefix + tail, title: "Ignored"), prefix + tail)
            }
        }
    }

    func testTitleByteBoundSurvivesLargeSingleGrapheme() throws {
        let url = "claude.ai/epitaxy/local_" + id
        for title in ["a" + String(repeating: "\u{0301}", count: 50_000),
                      String(repeating: "👨‍👩‍👧‍👦", count: 250),
                      String(repeating: " \t\n", count: 10_000)] {
            let observation = try XCTUnwrap(ClaudeDesktopObservation(url: url, title: title))
            XCTAssertLessThanOrEqual(observation.title.count, ClaudeDesktopObservation.maximumTitleCharacters)
            XCTAssertLessThanOrEqual(observation.title.utf8.count, ClaudeDesktopObservation.maximumTitleBytes)
        }
    }

    func testNotificationBurstKeepsFirstReadAndAllowsNextBurst() throws {
        let gate = ClaudeDesktopObservationGate()
        let first = try XCTUnwrap(gate.requestRead())
        // A trailing-edge debounce would replace the first request on every event.
        for _ in 0..<10_000 { XCTAssertNil(gate.requestRead()) }
        XCTAssertTrue(gate.beginRead(first))
        let second = try XCTUnwrap(gate.requestRead())
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.beginRead(first))
        XCTAssertTrue(gate.beginRead(second))
    }

    func testStoppedOrOldAttachmentReadCannotConsumeNewRequest() throws {
        let gate = ClaudeDesktopObservationGate()
        let old = try XCTUnwrap(gate.requestRead())
        gate.invalidate() // Stop, permission revocation, or departure from Claude.
        let replacement = try XCTUnwrap(gate.requestRead())
        XCTAssertFalse(gate.beginRead(old))
        XCTAssertFalse(gate.isCurrent(old))
        XCTAssertTrue(gate.beginRead(replacement))
        XCTAssertTrue(gate.isCurrent(replacement))
    }

    func testActivationRoundtripDropsInFlightDeliveryAndResetsDedupe() throws {
        let observation = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/chat/" + id, title: "A"))
        let gate = ClaudeDesktopObservationGate()
        let old = try XCTUnwrap(gate.requestRead())
        XCTAssertTrue(gate.beginRead(old))
        XCTAssertTrue(gate.acceptDelivery(observation, for: old))
        XCTAssertFalse(gate.acceptDelivery(observation, for: old))
        gate.invalidate() // A -> other app
        gate.invalidate() // other app -> A before the utility queue catches up
        XCTAssertFalse(gate.acceptDelivery(observation, for: old))
        let current = try XCTUnwrap(gate.requestRead())
        XCTAssertTrue(gate.beginRead(current))
        XCTAssertTrue(gate.acceptDelivery(observation, for: current))
        let renamed = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/chat/" + id, title: "Renamed"))
        XCTAssertFalse(gate.acceptDelivery(renamed, for: current), "A generated title change is not a user navigation")
        XCTAssertFalse(gate.acceptDelivery(renamed, for: current))
    }

    func testDroppedDeliveryDoesNotSuppressLaterMatchingObservation() throws {
        let observation = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/chat/" + id, title: "A"))
        let gate = ClaudeDesktopObservationGate()
        let dropped = try XCTUnwrap(gate.requestRead())
        XCTAssertTrue(gate.beginRead(dropped))
        // The main-queue foreground/permission guard fails; acceptDelivery is not called.
        let next = try XCTUnwrap(gate.requestRead())
        XCTAssertTrue(gate.beginRead(next))
        XCTAssertTrue(gate.acceptDelivery(observation, for: next))
    }
}
