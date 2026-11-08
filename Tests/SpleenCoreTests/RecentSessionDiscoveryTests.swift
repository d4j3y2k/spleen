import XCTest
@testable import SpleenCore

final class RecentSessionDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claudeID = "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef"

    func testClaudeVisitSurvivesLegacyMigrationAfterAuditEviction() throws {
        var memory = ContextMemory()
        memory.record(ContextEvent(key: ConversationKey(provider: .claude, id: claudeID), topic: "Retained Claude",
            kind: .selectedConversation, observedAt: now.addingTimeInterval(-100),
            source: "claude-desktop-accessibility", evidence: .observedSelection), now: now)
        for index in 0..<64 {
            memory.record(ContextEvent(key: ConversationKey(provider: .codex, id: "thr_background"),
                kind: .threadUpdated, observedAt: now.addingTimeInterval(Double(index) - 64),
                source: "hook", evidence: .lifecycle), now: now)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as? [String: Any])
        // Both the original legacy store and a store already written by the
        // incomplete migration must recover the observation in interactions.
        for alreadyMigrated in [false, true] {
            if alreadyMigrated { object["selections"] = [] } else { object.removeValue(forKey: "selections") }
            let restored = try JSONDecoder().decode(ContextMemory.self, from: JSONSerialization.data(withJSONObject: object))
            let roundtrip = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(restored))
            let entries = RecentSessionSnapshot(state: SavedState(), catalog: CatalogCache(), context: roundtrip, now: now, uptime: 1).entries
            XCTAssertEqual(entries.map(\.destination.threadID), [claudeID])
            XCTAssertEqual(entries.first?.destination.title, "Retained Claude")
            XCTAssertEqual(entries.first?.interaction.kind, .visit)
            var cleared = restored; cleared.clear()
            let clearedAgain = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(cleared))
            XCTAssertTrue(clearedAgain.observedSelections(at: now).isEmpty)
        }
    }

    func testRecoveryKeepsLatestObservationWithoutPromotingDispatchToVisit() throws {
        var memory = ContextMemory()
        let key = ConversationKey(provider: .claude, id: claudeID)
        memory.record(ContextEvent(key: key, topic: "Older", kind: .selectedConversation,
            observedAt: now.addingTimeInterval(-10), source: "claude-desktop-accessibility", evidence: .observedSelection), now: now)
        memory.record(ContextEvent(key: key, topic: "Latest", kind: .selectedConversation,
            observedAt: now.addingTimeInterval(-2), source: "claude-desktop-accessibility", evidence: .observedSelection), now: now)
        memory.record(ContextEvent(key: key, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let restored = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.observedSelections(at: now).count, 1)
        XCTAssertEqual(restored.observedSelections(at: now).first?.topic, "Latest")
        XCTAssertEqual(restored.observedSelections(at: now).first?.observedAt, now.addingTimeInterval(-2))
        XCTAssertEqual(RecentSessionSnapshot(state: SavedState(), catalog: CatalogCache(), context: restored, now: now, uptime: 1).entries.first?.interaction.kind, .selection)
    }

    func testNewCatalogSessionAppearsWithoutVisitAndUpdatesDoNotReorderIt() throws {
        var state = SavedState()
        state.destinations = [Destination(title: "Selected", threadID: "thr_selected", lastOpenedAt: now.addingTimeInterval(-10))]
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [
            CatalogEntry(id: "thr_new_chat", title: "New session", folder: "/fixture", updatedAt: now, createdAt: now.addingTimeInterval(-5)),
            CatalogEntry(id: "thr_older", title: "Older creation", folder: "/fixture", updatedAt: now, createdAt: now.addingTimeInterval(-60)),
            CatalogEntry(id: "thr_updated", title: "Only updated", folder: "/fixture", updatedAt: now)
        ]
        let snapshot = RecentSessionSnapshot(state: state, catalog: catalog, now: now, uptime: 1)
        XCTAssertEqual(snapshot.entries.map(\.destination.threadID), ["thr_new_chat", "thr_selected", "thr_older"])
        XCTAssertEqual(snapshot.entries.first?.interaction.label(at: now), "Created just now")
        XCTAssertTrue(snapshot.entries.first?.interaction.help.hasPrefix("Session created:") == true)
        XCTAssertEqual(NavigationCompass(state: state, catalog: catalog, now: now, uptime: 1).entries.first?.reason, .created)
        state.destinations.append(Destination(title: "Saved label", threadID: "thr_new_chat", lastOpenedAt: now.addingTimeInterval(-5)))
        let selected = RecentSessionSnapshot(state: state, catalog: catalog, now: now, uptime: 1).entries.first
        XCTAssertEqual(selected?.interaction.kind, .selection, "Navigation wins a timestamp tie with creation")
        XCTAssertEqual(selected?.destination.title, "Saved label")
    }

    func testCreatedSessionsRespectClearDisableRetentionAndScope() throws {
        var state = SavedState()
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [
            CatalogEntry(id: "thr_recent", title: "Recent", folder: "/fixture", updatedAt: now, createdAt: now.addingTimeInterval(-1)),
            CatalogEntry(id: "thr_hidden", title: "Hidden", folder: "/fixture", updatedAt: now, createdAt: now),
            CatalogEntry(id: "thr_external", title: "Excluded folder", folder: "/other", updatedAt: now, createdAt: now),
            CatalogEntry(id: "thr_future", title: "Future", folder: "/fixture", updatedAt: now.addingTimeInterval(1), createdAt: now.addingTimeInterval(1)),
            CatalogEntry(id: "thr_expired", title: "Expired", folder: "/fixture", updatedAt: now, createdAt: now.addingTimeInterval(-ContextMemory.retention))
        ]
        catalog.hiddenIDs = ["thr_hidden"]
        func entries() -> [RecentSession] { RecentSessionSnapshot(state: state, catalog: catalog, now: now, uptime: 1).entries }
        XCTAssertEqual(entries().map(\.destination.threadID), ["thr_recent"])
        state.rememberRecents = false
        XCTAssertTrue(entries().isEmpty)
        state.rememberRecents = true
        state.clearRecents(at: now)
        state = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(entries().isEmpty, "Catalog refresh cannot resurrect cleared creation history")
        catalog.entries.append(CatalogEntry(id: "thr_after_clear", title: "After clear", folder: "/fixture", updatedAt: now.addingTimeInterval(2), createdAt: now.addingTimeInterval(1)))
        XCTAssertEqual(RecentSessionSnapshot(state: state, catalog: catalog, now: now.addingTimeInterval(2), uptime: 3).entries.map(\.destination.threadID), ["thr_after_clear", "thr_future"])
    }

    func testCreationMetadataDecodesIndependentlyOfUpdatedTimeAndOldCaches() throws {
        let data = Data(#"{"data":[{"id":"thr_new_chat","name":"New","cwd":"/fixture","createdAt":100,"updatedAt":200},{"id":"thr_old_chat","name":"Old","cwd":"/fixture","updatedAt":200},{"id":"thr_invalid","name":"Invalid","cwd":"/fixture","createdAt":300,"updatedAt":200}],"nextCursor":null}"#.utf8)
        let entries = try CatalogDecoder.page(data, allowedFolders: ["/fixture"]).entries
        XCTAssertEqual(entries.count, 3)
        guard entries.count == 3 else { return }
        XCTAssertEqual(entries[0].createdAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(entries[1].createdAt)
        XCTAssertNil(entries[2].createdAt)
        XCTAssertEqual(try JSONDecoder().decode([CatalogEntry].self, from: JSONEncoder().encode(entries)), entries)
        let legacy = Data(#"{"id":"thr_legacy","title":"Legacy","folder":"/fixture","updatedAt":200}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CatalogEntry.self, from: legacy).createdAt)
    }
}
