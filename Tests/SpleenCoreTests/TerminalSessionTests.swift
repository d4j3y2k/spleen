import XCTest
@testable import SpleenCore

final class TerminalSessionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func session(_ host: TerminalHost = .rex, _ provider: ContextProvider = .claude,
                         id: UUID? = nil, start: UInt64 = 1_999_999_990_000_000) -> TerminalSession {
        TerminalSession(host: host, provider: provider, pid: 123, startMicroseconds: start, tty: "/dev/ttys007",
                        folder: "/fixture/sample", sessionID: id, title: "Fixture session")
    }

    func testSearchRecentsAndCompassShareRunningRoute() throws {
        let live = session()
        let catalog = CatalogCache()
        let state = TerminalSession.project([live], onto: SavedState(), catalog: catalog)
        let snapshot = PreparedContext(state: state, catalog: catalog, now: now, uptime: 1)
        XCTAssertEqual(snapshot.contextual.results(query: "Rex Claude Code sample").first?.terminal, live)
        XCTAssertEqual(snapshot.recentSessions.entries.first?.interaction.kind, .terminalLaunch)
        XCTAssertEqual(NavigationCompass(state: state, catalog: catalog, now: now, uptime: 1).ordered.first?.terminal, live)
        XCTAssertThrowsError(try live.destination.navigationURL)
        XCTAssertNil(try JSONDecoder().decode(Destination.self, from: JSONEncoder().encode(live.destination)).terminal)
        XCTAssertTrue(TerminalSession.project([], onto: SavedState(), catalog: catalog).destinations.isEmpty)
        let reused = session(start: live.startMicroseconds + 1)
        XCTAssertNotEqual(live.key, reused.key)
        XCTAssertFalse(live.matchesLiveRoute(reused))
        let identified = session(id: UUID())
        XCTAssertTrue(live.matchesLiveRoute(identified))
        XCTAssertFalse(identified.matchesLiveRoute(session(id: UUID())))
    }

    func testTabTitleReplacesGeneratedNameOnceTheConversationHasATopic() {
        let live = session()
        XCTAssertEqual(TerminalSession.tabTitle("  Fixture topic\n", provider: .claude), "Fixture topic")
        XCTAssertEqual(TerminalSession.tabTitle("✳ Fixture topic", provider: .claude), "Fixture topic")
        XCTAssertNil(TerminalSession.tabTitle("✳ Claude Code", provider: .claude))
        XCTAssertNil(TerminalSession.tabTitle("", provider: .claude))
        XCTAssertEqual(TerminalSession.tabTitle("Claude Code", provider: .codex), "Claude Code")
        let titled = live.retitled("Fixture topic")
        XCTAssertEqual(titled.destination.title, "Fixture topic")
        XCTAssertEqual(titled.key, live.key)
        XCTAssertTrue(live.matchesLiveRoute(titled))
    }

    func testCodexThreadUsesOneRouteAndPreservesSavedLabel() {
        let uuid = UUID(), live = session(.ghostty, .codex, id: uuid)
        var catalog = CatalogCache()
        catalog.folders = [live.folder]
        catalog.entries = [CatalogEntry(id: live.key.id, title: "Catalog title", folder: live.folder, updatedAt: now)]
        var saved = SavedState()
        var label = live.destination
        label.terminal = nil; label.title = "My label"; label.pinned = true
        saved.destinations = [label]
        let state = TerminalSession.project([live, live], onto: saved, catalog: catalog)
        let results = RelevanceSnapshot(state: state, catalog: catalog).ordered
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "My label")
        XCTAssertEqual(results.first?.terminal, live)
        XCTAssertTrue(results.first?.pinned == true)
        XCTAssertNil(saved.destinations[0].terminal)
        XCTAssertEqual(TerminalSession.project([live], onto: SavedState(), catalog: catalog).destinations.first?.title, "Catalog title")
        catalog.hiddenIDs = [live.key.id]
        XCTAssertTrue(TerminalSession.project([live], onto: SavedState(), catalog: catalog).destinations.isEmpty)
    }

    func testVisitBeatsLaunchAndClearHistoryDoesNotMoveRunningSessionUp() {
        let live = session(.terminal), catalog = CatalogCache()
        var base = SavedState(), context = ContextMemory()
        context.record(ContextEvent(key: live.key, kind: .selectedConversation, observedAt: now, source: "terminal-foreground",
                                    evidence: .observedSelection), now: now)
        let state = TerminalSession.project([live], onto: base, catalog: catalog)
        XCTAssertEqual(RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: now, uptime: 1).entries.first?.interaction.kind, .visit)
        XCTAssertTrue(FrontApplication.terminal(live.key).contains(live.key))
        XCTAssertFalse(FrontApplication.provider(.claude).contains(live.key))
        base.clearRecents(at: now)
        let cleared = TerminalSession.project([live], onto: base, catalog: catalog)
        XCTAssertTrue(RecentSessionSnapshot(state: cleared, catalog: catalog, now: now, uptime: 1).entries.isEmpty)
    }
}
