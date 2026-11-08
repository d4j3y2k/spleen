import XCTest
@testable import SpleenCore

final class CoreTests: XCTestCase {
    let first = "01234567-89ab-cdef-0123-456789abcdef"
    let second = "fedcba98-7654-3210-fedc-ba9876543210"
    func testCanonicalLinksAndOpaqueIDs() throws {
        XCTAssertEqual(try ThreadTarget(" \(first)\n").url.absoluteString, "codex://threads/\(first)")
        XCTAssertEqual(try ThreadTarget("codex://threads/\(first)").id, first)
        XCTAssertEqual(try ThreadTarget("thr_example123").id, "thr_example123")
    }
    func testRejectsUnsafeOrNonExistingChatRoutes() {
        for input in ["", "new", "codex://threads/new", "codex://new?prompt=hi", "https://example.com/\(first)",
                      "codex://threads/\(first)?prompt=hi", "codex://threads/\(first)#x", "codex://user@threads/\(first)",
                      "codex://threads:1/\(first)", "codex://threads/../settings", "codex://threads/\(first)/more",
                      "codex://threads/%30\(first)", "hello world", "codex://settings", "javascript:alert(1)",
                      "codex://threads/\(first)/", "codex://threads/\(first)?", "codex://threads/\(first)#"] {
            XCTAssertThrowsError(try ThreadTarget(input), input)
        }
    }
    func testSaveEditDeleteAndDeduplication() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: " One ", link: first, pinned: false)
        let id = state.destinations[0].id
        XCTAssertEqual(state.destinations[0].title, "One")
        XCTAssertThrowsError(try state.upsert(id: nil, title: "Duplicate", link: "codex://threads/\(first)", pinned: false))
        XCTAssertThrowsError(try state.upsert(id: nil, title: "  ", link: second, pinned: false))
        try state.upsert(id: id, title: "Edited", link: second, pinned: true)
        XCTAssertEqual(state.destinations[0].id, id)
        XCTAssertEqual(state.destinations[0].threadID, second)
        state.remove(id); XCTAssertTrue(state.destinations.isEmpty)
    }
    func testSearchRanksTitlesWithoutPinsDisplacingMatches() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: "My Spleen notes", link: first, pinned: true)
        try state.upsert(id: nil, title: "Spleen work", link: second, pinned: false)
        try state.upsert(id: nil, title: "Spléen", link: "thr_third123", pinned: false)
        XCTAssertEqual(state.results(query: " spleen ").map(\.title), ["Spléen", "Spleen work", "My Spleen notes"])
        XCTAssertEqual(state.results(query: "not found"), [])
        XCTAssertEqual(state.results(query: "").first?.threadID, first)
    }
    func testPinsRecencyAndRetention() throws {
        var state = SavedState()
        for (title, id) in [("One", first), ("Two", second), ("Three", "thr_third123")] {
            try state.upsert(id: nil, title: title, link: id, pinned: title != "Three")
        }
        XCTAssertThrowsError(try state.upsert(id: state.destinations[2].id, title: "Three", link: "thr_third123", pinned: true))
        state.destinations[0].pinned = false; state.destinations[1].pinned = false
        let date = Date()
        state.recordDispatch(state.destinations[1].id, at: date)
        XCTAssertEqual(state.results(query: "", now: date).first?.title, "Two")
        XCTAssertEqual(state.results(query: "", now: date.addingTimeInterval(31 * 86400)).first?.title, "One")
        state.clearRecents(); state.rememberRecents = false
        state.recordDispatch(state.destinations[1].id)
        XCTAssertNil(state.destinations[1].lastOpenedAt)
    }
    func testPersistenceRoundTripAndCorruptionPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = StateRepository(url: dir.appendingPathComponent("state.json"))
        XCTAssertEqual(try repo.load(), SavedState())
        var state = SavedState(); try state.upsert(id: nil, title: "One", link: first, pinned: true)
        state.shortcut = Shortcut(key: "K", control: false, option: true, command: true)
        try repo.save(state); XCTAssertEqual(try repo.load(), state)
        let corrupt = Data("{broken".utf8); try corrupt.write(to: repo.url)
        XCTAssertThrowsError(try repo.load())
        XCTAssertEqual(try Data(contentsOf: repo.url), corrupt)
    }
    func testRejectsUnsupportedStateAndShortcuts() throws {
        var state = SavedState(); state.version = 99; XCTAssertThrowsError(try state.validate())
        XCTAssertFalse(Shortcut(control: false, option: false, shift: true).isValid)
        XCTAssertFalse(Shortcut(key: "Unsupported").isValid)
        XCTAssertEqual(Shortcut().label, "⌃⌥Space")
    }
    func testFocusRestorationAndRepeatedDismissal() {
        var session = PanelSession()
        session.present(priorPID: 10)
        XCTAssertEqual(session.dismiss(.cancel, currentPID: 20, ownPID: 20), 10)
        XCTAssertNil(session.dismiss(.cancel, currentPID: 20, ownPID: 20))
        session.present(priorPID: 10)
        XCTAssertNil(session.dismiss(.cancel, currentPID: 30, ownPID: 20))
        session.present(priorPID: 10)
        XCTAssertNil(session.dismiss(.dispatch, currentPID: 20, ownPID: 20))
        session.present(priorPID: 10)
        XCTAssertNil(session.dismiss(.focusLoss, currentPID: 20, ownPID: 20))
        XCTAssertFalse(session.isPresented)
    }
}
