import XCTest
@testable import SpleenCore

final class ClaudeDesktopRecentsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let a = "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef"
    private let b = "desktop-code:local_11234567-89ab-cdef-0123-456789abcdef"
    private func event(_ id: String, title: String = "Same title", age: TimeInterval = 0,
                       kind: ContextEventKind = .selectedConversation, evidence: ContextEvidence = .observedSelection,
                       source: String = "claude-desktop-accessibility") -> ContextEvent {
        ContextEvent(key: ConversationKey(provider: .claude, id: id), topic: title, kind: kind,
            observedAt: now.addingTimeInterval(-age), source: source, evidence: evidence)
    }

    func testOnlyRetainedForegroundDesktopSelectionsCreateTargets() {
        var memory = ContextMemory()
        for item in [event(a), event(b, kind: .turnCompleted, evidence: .lifecycle),
                     event(b, kind: .spleenDispatch, evidence: .spleenInteraction),
                     event(b, source: "other-adapter"), event("not-a-chat-id"),
                     event("desktop-code:local_invalid"), event(b, age: -1)] { memory.record(item, now: now) }
        let visits = ClaudeDesktopRecents(memory, now: now)
        XCTAssertEqual(visits.entries.map(\.destination.threadID), [a])
        XCTAssertNil(visits.entries[0].destination.lastOpenedAt)
        XCTAssertTrue(ClaudeDesktopRecents(memory, now: now.addingTimeInterval(ContextMemory.retention + 1)).entries.isEmpty)
        XCTAssertTrue(ClaudeDesktopRecents(memory, now: now.addingTimeInterval(-1)).entries.isEmpty)
    }

    func testOrdinaryChatAndCodeWithSameUUIDRemainDistinct() throws {
        var memory = ContextMemory()
        let chat = "01234567-89ab-cdef-0123-456789abcdef"
        memory.record(event(a, title: "Code", age: 2), now: now)
        memory.record(event(chat, title: "Chat", age: 1), now: now)
        let visits = ClaudeDesktopRecents(memory, now: now)
        XCTAssertEqual(visits.entries.map(\.destination.threadID), [chat, a])
        XCTAssertEqual(visits.entries.map(\.destination.title), ["Chat", "Code"])
        XCTAssertEqual(Set(visits.entries.map(\.destination.id)).count, 2)
        let snapshot = RecentSessionSnapshot(state: SavedState(), catalog: CatalogCache(), context: memory, now: now, uptime: 1)
        XCTAssertEqual(snapshot.entries.map(\.destination.threadID), [chat, a])
    }

    func testDuplicateTitlesStableIdentityLatestNonemptyTitleAndRestart() throws {
        var memory = ContextMemory()
        for item in [event(a, age: 3), event(b, age: 2), event(a, title: "Renamed", age: 1), event(a, title: "")] {
            memory.record(item, now: now)
        }
        let visits = ClaudeDesktopRecents(memory, now: now)
        XCTAssertEqual(visits.entries.map(\.destination.title), ["Renamed", "Same title"])
        XCTAssertEqual(Set(visits.entries.map(\.destination.id)).count, 2)
        XCTAssertNotEqual(visits.entries[0].destination.id, UUID(uuidString: String(a.suffix(36))))
        let decoded = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(ClaudeDesktopRecents(decoded, now: now), visits)
        XCTAssertEqual(visits.entries[0].observedAt, now)
        var duplicateTitles = ContextMemory()
        duplicateTitles.record(event(a, age: 1), now: now); duplicateTitles.record(event(b), now: now)
        XCTAssertEqual(ClaudeDesktopRecents(duplicateTitles, now: now).entries.count, 2)
    }

    func testSavedOverridesAndHiddenRecentRemainsSuppressed() throws {
        var memory = ContextMemory(); memory.record(event(a), now: now)
        var state = SavedState()
        try state.upsert(id: nil, title: "My saved label", link: "claude://claude.ai/epitaxy/local_" + a.suffix(36), pinned: true)
        var cache = CatalogCache(); cache.policy = DiscoveryPolicy(excludedConversationIDs: [state.destinations[0].conversationKey])
        let saved = RelevanceSnapshot(state: state, catalog: cache, context: memory, now: now)
        XCTAssertEqual(saved.ordered, state.destinations)
        state.destinations.removeAll()
        XCTAssertTrue(RelevanceSnapshot(state: state, catalog: cache, context: memory, now: now).ordered.isEmpty)
        cache.policy?.excludedConversationIDs = []
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: cache, context: memory, now: now).ordered.count, 1)
    }

    func testNeutralFallbackKeepsVisitsButRetentionFallbackDoesNot() {
        var memory = ContextMemory(); memory.record(event(a), now: now)
        let prepared = PreparedContext(state: SavedState(), catalog: CatalogCache(), context: memory, now: now, uptime: 100)
        XCTAssertEqual(prepared.snapshot(now: now.addingTimeInterval(1801), uptime: 1901).ordered.map(\.threadID), [a])
        XCTAssertFalse(prepared.isFresh(now: now.addingTimeInterval(1801), uptime: 1901))
        XCTAssertTrue(prepared.snapshot(now: now.addingTimeInterval(ContextMemory.retention + 1), uptime: 101).ordered.isEmpty)
        XCTAssertTrue(prepared.snapshot(now: now.addingTimeInterval(1), uptime: 100 + ContextMemory.retention + 1).ordered.isEmpty)
        XCTAssertTrue(prepared.snapshot(now: now.addingTimeInterval(-1), uptime: 101).ordered.isEmpty)
    }

    func testClearDisableAndSharedAuditBoundRemoveCandidates() {
        var memory = ContextMemory(); memory.record(event(a), now: now)
        var cleared = memory; cleared.clear()
        XCTAssertTrue(ClaudeDesktopRecents(cleared, now: now).entries.isEmpty)
        var disabled = memory; disabled.setRecentsEnabled(false); disabled.setRecentsEnabled(true)
        XCTAssertTrue(ClaudeDesktopRecents(disabled, now: now).entries.isEmpty)
        var state = SavedState(); state.rememberRecents = false
        XCTAssertTrue(RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now).ordered.isEmpty)
        let before = ContextRelevanceSignature(memory, now: now)
        for index in 0..<ContextMemory.maximumEvents {
            memory.record(event(b, kind: .turnCompleted, evidence: .lifecycle, source: "lifecycle-\(index)"), now: now)
        }
        XCTAssertEqual(memory.events.count, ContextMemory.maximumEvents)
        XCTAssertEqual(ClaudeDesktopRecents(memory, now: now).entries.count, 1, "Lifecycle events cannot erase navigation")
        XCTAssertTrue(before.hasSameInteractions(as: ContextRelevanceSignature(memory, now: now)))
    }

    func testOlderObservationCanChangeCandidateSetWithoutChangingCurrentHint() {
        var memory = ContextMemory(); memory.record(event(a), now: now)
        let before = ContextRelevanceSignature(memory, now: now)
        memory.record(event(b, age: 20), now: now)
        XCTAssertEqual(memory.currentHint(at: now)?.key.id, a)
        XCTAssertNotEqual(before, ContextRelevanceSignature(memory, now: now))
        XCTAssertEqual(ClaudeDesktopRecents(memory, now: now).entries.count, 2)
    }

    func testObservedTitleSuffixIsNotStrippedTwice() {
        var memory = ContextMemory(); memory.record(event(a, title: "Notes - Claude Code"), now: now)
        XCTAssertEqual(ClaudeDesktopRecents(memory, now: now).entries.first?.destination.title, "Notes - Claude Code")
    }

    private func crowdedSnapshot(events: [ContextEvent], disabled: Bool = false, excluded: [ConversationKey] = []) -> RelevanceSnapshot {
        let current = Destination(title: "Database locks", threadID: "thr_current_fixture", lastOpenedAt: now)
        var state = SavedState(); state.rememberRecents = !disabled
        state.destinations = (0..<2).map { Destination(title: "Reference \($0)", threadID: "thr_pin_\($0)", pinned: true) } + [current]
        var catalog = CatalogCache()
        catalog.policy = DiscoveryPolicy(scope: .exactFolders, folders: ["/database", "/music"], excludedConversationIDs: excluded)
        catalog.entries = [CatalogEntry(id: current.threadID, title: current.title, folder: "/database", updatedAt: now)]
        catalog.entries += (0..<12).map { CatalogEntry(id: "thr_related_\($0)", title: "Database locks \($0)", folder: "/database", updatedAt: now.addingTimeInterval(-3600 - Double($0))) }
        catalog.entries.append(CatalogEntry(id: "thr_latest_music", title: "Music", folder: "/music", updatedAt: now.addingTimeInterval(-1)))
        var memory = ContextMemory()
        for item in events { memory.record(item, now: now) }
        memory.record(ContextEvent(key: ConversationKey(provider: .codex, id: "thr_previous_unavailable"), kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-1), source: "spleen", evidence: .spleenInteraction), now: now)
        memory.record(ContextEvent(key: current.conversationKey, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        return RelevanceSnapshot(state: state, catalog: catalog, context: memory, now: now)
    }

    func testRecentClaudeAlternativeSurvivesCrowdedCatalogAndPreservesReservedChoices() {
        let snapshot = crowdedSnapshot(events: [event(a, title: "Arrange melody", age: 120), event(b, title: "Loop instrument", age: 60)])
        XCTAssertEqual(snapshot.ordered.prefix(5).map(\.threadID), [b, "thr_pin_0", "thr_pin_1", a, "thr_latest_music"])
        XCTAssertEqual(snapshot.subtitles[ConversationKey(provider: .claude, id: b)], "Claude Code · Experimental · Recently visited")
        XCTAssertEqual(snapshot.ordered.last?.threadID, "thr_current_fixture")
        XCTAssertEqual(Set(snapshot.ordered.map(\.conversationKey)).count, snapshot.ordered.count)
        XCTAssertEqual(snapshot.results(query: "Claude Code").map(\.threadID), [b, a])
        XCTAssertEqual(snapshot.results(query: "Codex").count, snapshot.ordered.filter { $0.provider == .codex }.count)
    }

    func testOnlyRecentEligibleVisitsGetAVisibleSlot() {
        for events in [
            [event(a, age: 86401)],
            [event(a, kind: .turnCompleted, evidence: .lifecycle)],
            [event(a, kind: .spleenDispatch, evidence: .spleenInteraction)],
            [event(a, age: -1)]
        ] {
            XCTAssertFalse(crowdedSnapshot(events: events).ordered.prefix(5).contains { $0.provider == .claude })
        }
        XCTAssertEqual(crowdedSnapshot(events: [event(a, age: 86401)]).results(query: "Claude").count, 1,
                       "Older retained visits remain searchable without taking a visible slot")
        XCTAssertFalse(crowdedSnapshot(events: [event(a)], disabled: true).ordered.contains { $0.provider == .claude })
        XCTAssertFalse(crowdedSnapshot(events: [event(a)], excluded: [ConversationKey(provider: .claude, id: a)]).ordered.contains { $0.provider == .claude })
    }

    func testRecentWorkJoinsAnAlreadyVisibleClaudePin() {
        let current = Destination(title: "Database locks", threadID: "thr_current_fixture", lastOpenedAt: now)
        let pinned = Destination(title: "My saved Claude", threadID: a, pinned: true, provider: .claude)
        var state = SavedState(); state.destinations = [current, pinned]
        var catalog = CatalogCache(); catalog.folders = ["/database"]
        catalog.entries = [CatalogEntry(id: current.threadID, title: current.title, folder: "/database", updatedAt: now)]
        catalog.entries += (0..<8).map { CatalogEntry(id: "thr_related_\($0)", title: "Database locks \($0)", folder: "/database", updatedAt: now) }
        var memory = ContextMemory()
        memory.record(event(b, title: "Music", age: 120), now: now)
        memory.record(ContextEvent(key: ConversationKey(provider: .codex, id: "thr_previous_unavailable"), kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-1), source: "spleen", evidence: .spleenInteraction), now: now)
        memory.record(ContextEvent(key: current.conversationKey, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, context: memory, now: now)
        XCTAssertEqual(snapshot.ordered[1], pinned)
        XCTAssertEqual(snapshot.ordered.prefix(5).filter { $0.provider == .claude }.count, 2)
        XCTAssertEqual(snapshot.ordered.first?.threadID, b, "An existing Claude pin must not crowd out different recent work")
    }

    func testRecentSelectionsRefreshKnownClaudeCandidatesWithoutInventingVisits() {
        let selectedA = event(a, age: 120, kind: .spleenDispatch, evidence: .spleenInteraction, source: "spleen")
        let selectedB = event(b, age: 60, kind: .spleenDispatch, evidence: .spleenInteraction, source: "spleen")
        let snapshot = crowdedSnapshot(events: [event(a, age: 7300), event(b, age: 7200), selectedA, selectedB])
        XCTAssertEqual(snapshot.ordered.prefix(5).map(\.threadID), [b, "thr_pin_0", "thr_pin_1", a, "thr_latest_music"])
        let preview = snapshot.previews[ConversationKey(provider: .claude, id: b)]
        XCTAssertEqual(preview?.lastVisitedAt, now.addingTimeInterval(-7200))
        XCTAssertEqual(preview?.lastSelectedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(preview?.timestamp(at: now)?.kind, .selection)
        XCTAssertEqual(preview?.timestamp(at: now)?.label(at: now), "Last selected 1m ago")
        XCTAssertNil(preview?.timing, "A selection timestamp must not be presented as a completed reply")
        XCTAssertTrue(crowdedSnapshot(events: [selectedA, selectedB]).results(query: "Claude").isEmpty,
                      "Dispatch alone cannot discover a new Desktop identity")
    }

    func testLastObservedClaudeRemainsNearbyInACrowdedPicker() {
        var state = SavedState()
        let current = Destination(title: "Database locks", threadID: "thr_current_fixture", lastOpenedAt: now.addingTimeInterval(-1))
        let pin = Destination(title: "Reference", threadID: "thr_pin_fixture", pinned: true)
        state.destinations = [pin, current]
        var memory = ContextMemory(); memory.record(event(a, title: "New Claude session"), now: now)
        var catalog = CatalogCache(); catalog.folders = ["/database"]
        catalog.entries = (0..<8).map { CatalogEntry(id: "thr_related_\($0)", title: "Database locks \($0)", folder: "/database", updatedAt: now) }
        let fromClaude = RelevanceSnapshot(state: state, catalog: catalog, context: memory, now: now)
        XCTAssertTrue(fromClaude.ordered.prefix(5).contains { $0.threadID == a }, "A last-observed selection is not continuous foreground tracking")
        XCTAssertNotEqual(fromClaude.ordered.first?.threadID, a, "The center can still recommend a different conversation")
        XCTAssertTrue(fromClaude.ordered.prefix(5).contains(pin))
        XCTAssertEqual(fromClaude.subtitles[ConversationKey(provider: .claude, id: a)], "Claude Code · Experimental · Recently visited")
        XCTAssertEqual(fromClaude.results(query: "New Claude session").first?.threadID, a)
    }

    func testOlderClaudePinDoesNotHideNewestObservedSession() {
        let oldPin = Destination(title: "Pinned Claude", threadID: b, pinned: true, provider: .claude)
        var state = SavedState(); state.destinations = [oldPin]
        var memory = ContextMemory(); memory.record(event(a, title: "New Claude session"), now: now)
        var catalog = CatalogCache(); catalog.folders = ["/database"]
        catalog.entries = (0..<8).map { CatalogEntry(id: "thr_related_\($0)", title: "Database locks \($0)", folder: "/database", updatedAt: now) }
        let prepared = PreparedContext(state: state, catalog: catalog, context: memory, now: now, uptime: 100)
        let snapshot = prepared.snapshot(now: now, uptime: 100)
        XCTAssertTrue(snapshot.ordered.prefix(5).contains(oldPin))
        XCTAssertTrue(snapshot.ordered.prefix(5).contains { $0.threadID == a }, "An older Claude pin must not satisfy the newest-visit slot")
        XCTAssertEqual(snapshot.ordered.prefix(5).filter { $0.provider == .claude }.count, 2)
        XCTAssertEqual(Set(snapshot.ordered.map(\.conversationKey)).count, snapshot.ordered.count)
    }
}
