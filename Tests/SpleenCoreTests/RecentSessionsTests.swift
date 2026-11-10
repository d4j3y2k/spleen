import XCTest
@testable import SpleenCore

final class RecentSessionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(_ state: SavedState, catalog: CatalogCache = CatalogCache(), context: ContextMemory = ContextMemory()) -> RecentSessionSnapshot {
        RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: now, uptime: 100)
    }

    func testChronologicalDistinctOrderIgnoresPinsAndBackgroundUpdates() {
        var state = SavedState()
        state.destinations = [Destination(title: "Pinned", threadID: "thr_pinned", pinned: true),
                              Destination(title: "Newer", threadID: "thr_newer"),
                              Destination(title: "Background only", threadID: "thr_background")]
        state.destinations[0].lastOpenedAt = now.addingTimeInterval(-3600)
        state.destinations[1].lastOpenedAt = now.addingTimeInterval(-60)
        var context = ContextMemory()
        context.record(ContextEvent(key: state.destinations[0].conversationKey, kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-30), source: "spleen", evidence: .spleenInteraction), now: now)
        context.record(ContextEvent(key: state.destinations[2].conversationKey, kind: .turnCompleted,
            observedAt: now, source: "hook", evidence: .lifecycle), now: now)
        let entries = snapshot(state, context: context).entries
        XCTAssertEqual(entries.map(\.destination.threadID), ["thr_pinned", "thr_newer"])
        XCTAssertEqual(entries.first?.interaction.date, now.addingTimeInterval(-30))
    }

    func testObservedClaudeAndDispatchedCodexMergeWithSavedOverrides() {
        let codeID = "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef"
        var context = ContextMemory()
        context.record(ContextEvent(key: ConversationKey(provider: .claude, id: codeID), topic: "Observed title",
            kind: .selectedConversation, observedAt: now.addingTimeInterval(-120),
            source: "claude-desktop-accessibility", evidence: .observedSelection), now: now)
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [CatalogEntry(id: "thr_dispatched", title: "Discovered", folder: "/fixture", updatedAt: now)]
        context.record(ContextEvent(key: catalog.entries[0].destination.conversationKey, kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-60), source: "spleen", evidence: .spleenInteraction), now: now)
        var state = SavedState()
        state.destinations = [Destination(title: "Saved label", threadID: codeID, provider: .claude)]
        let entries = snapshot(state, catalog: catalog, context: context).entries
        XCTAssertEqual(entries.map(\.destination.title), ["Discovered", "Saved label"])
        XCTAssertEqual(entries.last?.destination.id, state.destinations[0].id)
        XCTAssertEqual(entries.last?.interaction.kind, .visit)
        catalog.hiddenIDs = ["thr_dispatched"]
        state.destinations = []
        var policy = catalog.effectivePolicy
        policy.excludedConversationIDs = [ConversationKey(provider: .claude, id: codeID)]
        catalog.policy = policy
        XCTAssertTrue(snapshot(state, catalog: catalog, context: context).entries.isEmpty)
    }

    func testDispatchCannotInventAnUnknownClaudeDestination() {
        var memory = ContextMemory()
        memory.record(ContextEvent(key: ConversationKey(provider: .claude, id: "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef"),
            kind: .spleenDispatch, observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        XCTAssertTrue(snapshot(SavedState(), context: memory).entries.isEmpty)
    }

    func testDisabledFutureAndExpiredHistoryDoNotAppear() {
        var state = SavedState()
        state.destinations = (0..<3).map { Destination(title: "Session \($0)", threadID: "thr_time_\($0)") }
        state.destinations[0].lastOpenedAt = now.addingTimeInterval(1)
        state.destinations[1].lastOpenedAt = now.addingTimeInterval(-ContextMemory.retention)
        state.destinations[2].lastOpenedAt = now.addingTimeInterval(-1)
        XCTAssertEqual(snapshot(state).entries.map(\.destination.threadID), ["thr_time_2"])
        state.rememberRecents = false
        XCTAssertTrue(snapshot(state).entries.isEmpty)
    }

    func testThirtyMinuteRankingExpiryDoesNotClearRecentSessions() {
        var state = SavedState()
        state.destinations = [Destination(title: "Visited", threadID: "thr_visit")]
        state.destinations[0].lastOpenedAt = now.addingTimeInterval(-60)
        let prepared = PreparedContext(state: state, catalog: CatalogCache(), now: now, uptime: 100)
        XCTAssertEqual(prepared.recentSessions.visibleEntries(now: now.addingTimeInterval(3600), uptime: 3700).count, 1)
        XCTAssertTrue(prepared.recentSessions.visibleEntries(now: now.addingTimeInterval(ContextMemory.retention), uptime: 100 + ContextMemory.retention).isEmpty)
        XCTAssertTrue(prepared.recentSessions.visibleEntries(now: now.addingTimeInterval(-1), uptime: 100).isEmpty)
        XCTAssertTrue(prepared.recentSessions.visibleEntries(now: now, uptime: 99).isEmpty)
    }

    func testHistorySurvivesLifecycleAuditEviction() throws {
        var state = SavedState()
        state.destinations = [Destination(title: "Older selection", threadID: "thr_retained")]
        var memory = ContextMemory()
        memory.record(ContextEvent(key: state.destinations[0].conversationKey, kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-100), source: "spleen", evidence: .spleenInteraction), now: now)
        for index in 0..<64 {
            memory.record(ContextEvent(key: ConversationKey(provider: .codex, id: "thr_background"), kind: .threadUpdated,
                observedAt: now.addingTimeInterval(Double(index) - 64), source: "hook", evidence: .lifecycle), now: now)
        }
        let restored = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertFalse(restored.events.contains { $0.kind == .spleenDispatch })
        XCTAssertEqual(snapshot(state, context: restored).entries.count, 1)
    }

    func testProviderIdentityAndDeterministicTies() {
        var state = SavedState()
        state.destinations = [Destination(title: "Codex", threadID: "01234567-89ab-cdef-0123-456789abcdef"),
            Destination(title: "Claude", threadID: "01234567-89ab-cdef-0123-456789abcdef", provider: .claude)]
        for index in state.destinations.indices { state.destinations[index].lastOpenedAt = now }
        let first = snapshot(state).entries
        state.destinations.reverse()
        XCTAssertEqual(snapshot(state).entries, first)
        XCTAssertEqual(first.count, 2)
    }

    func testListIsBoundedToMostRecent64Sessions() {
        var state = SavedState()
        state.destinations = (0..<100).map { index in
            var item = Destination(title: "Session \(index)", threadID: "thr_bound_\(index)")
            item.lastOpenedAt = now.addingTimeInterval(-Double(index))
            return item
        }
        let entries = snapshot(state).entries
        XCTAssertEqual(entries.count, 64)
        XCTAssertEqual(entries.last?.destination.threadID, "thr_bound_63")
    }

    func testOldestExpiryKeepsNewerEntriesAndRewindFailsClosed() {
        var state = SavedState()
        state.destinations = [
            Destination(title: "Old", threadID: "thr_old", lastOpenedAt: now.addingTimeInterval(-ContextMemory.retention + 60)),
            Destination(title: "New", threadID: "thr_new", lastOpenedAt: now.addingTimeInterval(-7200))]
        let recents = snapshot(state)
        XCTAssertEqual(recents.visibleEntries(now: now, uptime: 100).map(\.destination.threadID), ["thr_new", "thr_old"])
        let later = now.addingTimeInterval(120)
        XCTAssertFalse(recents.isFresh(now: later, uptime: 220), "the oldest entry expired, so a rebuild is due")
        XCTAssertEqual(recents.visibleEntries(now: later, uptime: 220).map(\.destination.threadID), ["thr_new"],
                       "one expiry must not empty the list")
        XCTAssertEqual(recents.visibleEntries(now: now.addingTimeInterval(30), uptime: 220).map(\.destination.threadID), ["thr_new"],
                       "monotonic time still ages entries after a wall-clock adjustment")
        XCTAssertTrue(recents.visibleEntries(now: now.addingTimeInterval(-1), uptime: 100).isEmpty, "a clock moved backwards fails closed")
    }
}
