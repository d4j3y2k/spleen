import XCTest
@testable import SpleenCore

final class NavigationCompassTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func build(_ state: SavedState, catalog: CatalogCache = CatalogCache(),
                       context: ContextMemory = ContextMemory(), current: ConversationKey? = nil) -> NavigationCompass {
        NavigationCompass(state: state, catalog: catalog, context: context, currentKey: current, now: now, uptime: 100)
    }
    func testActualRecentsWinWithoutThirtyMinuteCliffOrCatalogBackfill() {
        var state = SavedState()
        state.destinations = (0..<6).map { index in
            Destination(title: "Recent \(index)", threadID: "thr_recent_\(index)", lastOpenedAt: now.addingTimeInterval(-Double(index + 1) * 3600))
        }
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [CatalogEntry(id: "thr_old", title: "Old unfinished task", folder: "/fixture", updatedAt: now)]
        let compass = build(state, catalog: catalog)
        XCTAssertEqual(compass.visibleEntries(now: now, uptime: 100).map(\.destination.threadID), (0..<5).map { "thr_recent_\($0)" })
        XCTAssertEqual(compass.visibleEntries(now: now.addingTimeInterval(7200), uptime: 7300).map(\.destination.threadID), (0..<5).map { "thr_recent_\($0)" })
        XCTAssertFalse(compass.ordered.contains { $0.threadID == "thr_old" })
    }
    func testCurrentDefersWithoutReorderingAlternativesAndPinsCannotCrowd() {
        var state = SavedState()
        state.destinations = (0..<6).map { Destination(title: "Recent \($0)", threadID: "thr_\($0)", lastOpenedAt: now.addingTimeInterval(-Double($0 + 1))) }
        state.destinations.insert(Destination(title: "Pin", threadID: "thr_pin", pinned: true), at: 0)
        let compass = build(state, current: state.destinations[1].conversationKey)
        XCTAssertEqual(compass.ordered.map(\.threadID), ["thr_1", "thr_2", "thr_3", "thr_4", "thr_5", "thr_0", "thr_pin"])
        XCTAssertEqual(compass.visibleEntries(now: now, uptime: 100).count, 5)
    }
    func testLifecycleAndInferredPromptNeverBecomeNavigation() {
        var state = SavedState(); state.destinations = [Destination(title: "Background", threadID: "thr_background")]
        var memory = ContextMemory()
        memory.record(ContextEvent(key: state.destinations[0].conversationKey, kind: .turnCompleted, observedAt: now, source: "hook", evidence: .lifecycle), now: now)
        memory.record(ContextEvent(key: state.destinations[0].conversationKey, kind: .userPromptSubmitted, observedAt: now, source: "hook", evidence: .inferredHumanActivity), now: now)
        XCTAssertTrue(build(state, context: memory).ordered.isEmpty)
    }
    func testHiddenExcludedAndDisabledHistoryRespectControls() {
        var state = SavedState(); state.destinations = [Destination(title: "Pin", threadID: "thr_pin", pinned: true, lastOpenedAt: now)]
        var catalog = CatalogCache(); catalog.hiddenIDs = ["thr_pin"]
        XCTAssertTrue(build(state, catalog: catalog).ordered.isEmpty)
        catalog.hiddenIDs = []; var policy = catalog.effectivePolicy; policy.excludedConversationIDs = [state.destinations[0].conversationKey]; catalog.policy = policy
        XCTAssertTrue(build(state, catalog: catalog).ordered.isEmpty)
        state.rememberRecents = false
        let compass = build(state)
        XCTAssertEqual(compass.entries.first?.reason, .pinned)
        XCTAssertNil(compass.entries.first?.interaction)
        state.destinations[0].pinned = false
        XCTAssertTrue(build(state).ordered.isEmpty)
    }
    func testExpiredOrRewoundSnapshotDoesNotExposeHistory() {
        var state = SavedState(); state.destinations = [Destination(title: "Visit", threadID: "thr_visit", lastOpenedAt: now)]
        let compass = build(state)
        XCTAssertTrue(compass.visibleEntries(now: now.addingTimeInterval(ContextMemory.retention), uptime: 100 + ContextMemory.retention).isEmpty)
        XCTAssertTrue(compass.visibleEntries(now: now, uptime: 99).isEmpty)
        XCTAssertTrue(compass.visibleEntries(now: now, uptime: 100, limit: 0).isEmpty)
    }
    func testOneExpiredVisitKeepsNewerVisitsAndPins() {
        var state = SavedState()
        state.destinations = [
            Destination(title: "Old", threadID: "thr_old", lastOpenedAt: now.addingTimeInterval(-ContextMemory.retention + 60)),
            Destination(title: "New", threadID: "thr_new", lastOpenedAt: now.addingTimeInterval(-60)),
            Destination(title: "Pin", threadID: "thr_pin", pinned: true, lastOpenedAt: now.addingTimeInterval(-ContextMemory.retention + 30))]
        let compass = build(state)
        XCTAssertEqual(compass.visibleEntries(now: now, uptime: 100).map(\.destination.threadID), ["thr_new", "thr_old", "thr_pin"])
        XCTAssertEqual(compass.visibleEntries(now: now.addingTimeInterval(120), uptime: 220).map(\.destination.threadID), ["thr_new", "thr_pin"],
                       "the oldest visit expiring must not empty the compass before the next rebuild")
    }
}
