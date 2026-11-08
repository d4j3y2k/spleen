import XCTest
@testable import SpleenCore

final class ContextTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func event(_ id: String, provider: ContextProvider = .codex, offset: TimeInterval = 0,
               kind: ContextEventKind = .spleenDispatch, evidence: ContextEvidence = .spleenInteraction) -> ContextEvent {
        ContextEvent(key: ConversationKey(provider: provider, id: id), project: "/project",
                     kind: kind, observedAt: now.addingTimeInterval(offset), source: "test", evidence: evidence)
    }

    func testPreviousDistinctAcrossProvidersAndRepeatedSelection() throws {
        var memory = ContextMemory()
        memory.record(event("same", offset: -3), now: now)
        memory.record(event("same", provider: .claude, offset: -2), now: now)
        memory.record(event("same", provider: .claude, offset: -1), now: now)
        XCTAssertEqual(memory.currentHint(at: now)?.key, ConversationKey(provider: .claude, id: "same"))
        XCTAssertEqual(memory.previousDistinct(at: now)?.key, ConversationKey(provider: .codex, id: "same"))
        XCTAssertEqual(memory.transitions(at: now).count, 1)
        XCTAssertFalse(memory.record(event("same", provider: .claude, offset: -1), now: now))
        memory.record(event("same"), now: now)
        XCTAssertEqual(memory.previousDistinct(at: now)?.key.provider, .claude)
        XCTAssertEqual(memory.transitions(at: now).count, 2)
        let restored = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.currentHint(at: now), memory.currentHint(at: now))
        XCTAssertEqual(restored.previousDistinct(at: now), memory.previousDistinct(at: now))
    }

    func testLifecycleAndBackgroundNeverClaimAttention() {
        var memory = ContextMemory()
        memory.record(event("viewed", offset: -10, kind: .selectedConversation, evidence: .observedSelection), now: now)
        for (kind, evidence) in [(ContextEventKind.threadUpdated, ContextEvidence.observedSelection),
                                  (.turnCompleted, .lifecycle), (.sessionStarted, .lifecycle),
                                  (.userPromptSubmitted, .background)] {
            memory.record(event("background", offset: -5, kind: kind, evidence: evidence), now: now)
        }
        XCTAssertEqual(memory.currentHint(at: now)?.key.id, "viewed")
        XCTAssertNil(memory.previousDistinct(at: now))
        memory.record(event("human", kind: .userPromptSubmitted, evidence: .inferredHumanActivity), now: now)
        XCTAssertEqual(memory.currentHint(at: now)?.evidence, .inferredHumanActivity)
        XCTAssertEqual(memory.previousDistinct(at: now)?.key.id, "viewed")
        XCTAssertEqual(memory.latestObservedSelection(at: now)?.key.id, "viewed")
        var dispatch = ContextMemory()
        dispatch.record(event("dispatch"), now: now)
        XCTAssertNil(dispatch.latestObservedSelection(at: now))
    }

    func testOutOfOrderFutureAndStaleEvents() {
        var memory = ContextMemory()
        memory.record(event("a", offset: -20), now: now)
        memory.record(event("b", offset: -10), now: now)
        memory.record(event("late", offset: -15), now: now)
        memory.record(event("tie", offset: -10), now: now)
        XCTAssertEqual(memory.currentHint(at: now)?.key.id, "b")
        XCTAssertEqual(memory.previousDistinct(at: now)?.key.id, "a")
        XCTAssertFalse(memory.record(event("future", offset: 1), now: now))
        XCTAssertFalse(memory.record(event("expired", offset: -ContextMemory.retention - 1), now: now))
        XCTAssertNil(memory.currentHint(at: now.addingTimeInterval(ContextMemory.hintLifetime + 1)))
        XCTAssertEqual(memory.previousDistinct(at: now.addingTimeInterval(ContextMemory.hintLifetime + 1))?.key.id, "a")
        memory.prune(now: now.addingTimeInterval(ContextMemory.retention + 1))
        XCTAssertTrue(memory.events.isEmpty)
        XCTAssertNil(memory.previousDistinct(at: now.addingTimeInterval(ContextMemory.retention + 1)))
    }

    func testBoundsAndClearControls() {
        var memory = ContextMemory()
        for index in 0..<100 { memory.record(event("\(index)", offset: TimeInterval(index - 100)), now: now) }
        XCTAssertEqual(memory.events.count, ContextMemory.maximumEvents)
        XCTAssertEqual(memory.transitions(at: now).count, ContextMemory.maximumEvents - 1)
        memory.setRecentsEnabled(false)
        XCTAssertTrue(memory.events.isEmpty)
        XCTAssertFalse(memory.record(event("ignored"), now: now))
        memory.setRecentsEnabled(true)
        XCTAssertNil(memory.currentHint(at: now))
        memory.record(event("new"), now: now)
        memory.clear()
        XCTAssertTrue(memory.events.isEmpty)
        XCTAssertNil(memory.currentHint(at: now))
    }

    func testVersionValidation() throws {
        let data = try JSONEncoder().encode(ContextMemory())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        XCTAssertThrowsError(try JSONDecoder().decode(ContextMemory.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testOptionalTopicPreservesLegacyStoresAndBoundedTitleEvidence() throws {
        var memory = ContextMemory()
        let key = ConversationKey(provider: .claude, id: "desktop-code:local_fixture")
        let selection = ContextEvent(key: key, topic: String(repeating: "x", count: 300), kind: .selectedConversation,
                                     observedAt: now, source: "claude-accessibility", evidence: .observedSelection)
        XCTAssertEqual(selection.topic?.count, 280)
        memory.record(selection, now: now)
        let restored = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        XCTAssertEqual(restored.currentHint(at: now)?.topic?.count, 280)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(memory)) as? [String: Any])
        for field in ["events", "interactions"] {
            legacy[field] = try XCTUnwrap(legacy[field] as? [[String: Any]]).map { original -> [String: Any] in
                var row = original; row.removeValue(forKey: "topic"); return row
            }
        }
        let old = try JSONDecoder().decode(ContextMemory.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.currentHint(at: now)?.topic)
        XCTAssertEqual(old.currentHint(at: now)?.key, key)
        XCTAssertNoThrow(try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(old)))
        var lifecycle = ContextMemory()
        lifecycle.record(ContextEvent(key: key, topic: "SQLite transaction locks", kind: .turnCompleted,
                                      observedAt: now, source: "code-hook", evidence: .lifecycle), now: now)
        XCTAssertNil(lifecycle.currentHint(at: now))
        XCTAssertNil(lifecycle.latestObservedSelection(at: now))
    }

    func testDiscoveryDefaultsMigrationAndExclusions() throws {
        let codex = ConversationKey(provider: .codex, id: "same"), claude = ConversationKey(provider: .claude, id: "same")
        var policy = DiscoveryPolicy()
        XCTAssertTrue(policy.allows(folder: "/new/project", key: codex))
        XCTAssertFalse(policy.allows(folder: "relative", key: codex))
        policy.excludedFolders = ["/private/work/"]
        policy.excludedConversationIDs = [codex]
        XCTAssertFalse(policy.allows(folder: "/personal", key: codex))
        XCTAssertTrue(policy.allows(folder: "/personal", key: claude))
        XCTAssertFalse(policy.allows(folder: "/private/work/subproject", key: claude))
        XCTAssertTrue(policy.allows(folder: "/private/workbench", key: claude))
        let legacy = DiscoveryPolicy.legacy(folders: ["/personal/project"])
        XCTAssertFalse(legacy.allows(folder: "/new/project", key: codex))
        XCTAssertFalse(legacy.allows(folder: "/personal/project/child", key: codex))
        XCTAssertTrue(legacy.allows(folder: "/personal/./project/", key: codex))
        XCTAssertFalse(DiscoveryPolicy.legacy(folders: []).allows(folder: "/new/project", key: codex))
        XCTAssertEqual(try JSONDecoder().decode(DiscoveryPolicy.self, from: JSONEncoder().encode(policy)), policy)
    }

    func testDiscoveryPaginationAndCacheBounds() throws {
        let policy = DiscoveryPolicy(pageSize: 10000, maxPages: 10000, cacheTTL: 0)
        XCTAssertEqual(policy.maximumEntries, 1000)
        XCTAssertEqual(policy.cacheTTL, 30)
        XCTAssertTrue(policy.shouldRefresh(lastRefreshedAt: nil, now: now))
        XCTAssertFalse(policy.shouldRefresh(lastRefreshedAt: now.addingTimeInterval(-29), now: now))
        XCTAssertTrue(policy.shouldRefresh(lastRefreshedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(policy.shouldRefresh(lastRefreshedAt: now.addingTimeInterval(1), now: now))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any])
        object["maxPages"] = 100000
        XCTAssertThrowsError(try JSONDecoder().decode(DiscoveryPolicy.self, from: JSONSerialization.data(withJSONObject: object)))
        var changed = DiscoveryPolicy()
        changed.pageSize = 0; changed.maxPages = Int.max; changed.cacheTTL = .infinity
        XCTAssertEqual(changed.pageSize, 1)
        XCTAssertEqual(changed.maxPages, 10)
        XCTAssertEqual(changed.cacheTTL, 300)
    }
    func testObservedNavigationSurvivesBusyStatusAndSameSessionDispatch() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let key = ConversationKey(provider: .codex, id: "01234567-89ab-cdef-0123-456789abcdef")
        var memory = ContextMemory()
        memory.record(ContextEvent(key: key, topic: "Navigation", kind: .selectedConversation,
            observedAt: now.addingTimeInterval(-2), source: "codex-desktop-accessibility", evidence: .observedSelection), now: now)
        memory.record(ContextEvent(key: key, kind: .spleenDispatch, observedAt: now.addingTimeInterval(-1),
            source: "spleen", evidence: .spleenInteraction), now: now)
        for n in 0..<100 {
            memory.record(ContextEvent(key: key, kind: .threadUpdated, observedAt: now,
                source: "background-\(n)", evidence: .background), now: now)
        }
        XCTAssertEqual(memory.observedSelections(at: now).count, 1)
        let reloaded = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(memory))
        let snapshot = RecentSessionSnapshot(state: SavedState(), catalog: CatalogCache(), context: reloaded, now: now, uptime: 0)
        XCTAssertEqual(snapshot.entries.first?.destination.threadID, key.id)
        XCTAssertEqual(snapshot.entries.first?.interaction.date, now.addingTimeInterval(-1))
        var hidden = CatalogCache(); hidden.hiddenIDs = [key.id]
        XCTAssertTrue(RecentSessionSnapshot(state: SavedState(), catalog: hidden, context: reloaded, now: now, uptime: 0).entries.isEmpty)
        var cleared = reloaded; cleared.clear()
        XCTAssertTrue(cleared.observedSelections(at: now).isEmpty)
    }

}
