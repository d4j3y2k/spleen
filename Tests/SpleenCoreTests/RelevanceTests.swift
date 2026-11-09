import XCTest
@testable import SpleenCore

final class RelevanceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func testPreviewsUseOnlyCurrentScopedNotesAndKeepProvidersSeparate() {
        let sharedID = "01234567-89ab-cdef-0123-456789abcdef"
        let codex = Destination(title: "Ranking", threadID: sharedID)
        let claude = Destination(title: "Planning", threadID: sharedID, provider: .claude)
        let stale = Destination(title: "Stale", threadID: "thr_preview_stale")
        let excluded = Destination(title: "Excluded", threadID: "thr_preview_excluded")
        var state = SavedState(); state.destinations = [codex, claude, stale, excluded]
        var catalog = CatalogCache(); catalog.folders = ["/personal/Spleen"]
        catalog.entries = [
            CatalogEntry(id: sharedID, title: "Provider title", folder: "/personal/Spleen", updatedAt: now),
            CatalogEntry(id: stale.threadID, title: stale.title, folder: "/personal/Spleen", updatedAt: now),
            CatalogEntry(id: excluded.threadID, title: excluded.title, folder: "/outside", updatedAt: now)
        ]
        let notes = [
            ThreadInsight(id: sharedID, folder: "/personal/Spleen", updatedAt: now, topic: "  Compare suggested conversations.  ",
                timing: TurnTiming(lastCompletedAt: now.addingTimeInterval(-120), checkedAt: now)),
            ThreadInsight(id: stale.threadID, folder: "/personal/Spleen", updatedAt: now.addingTimeInterval(-1), topic: "Old excerpt"),
            ThreadInsight(id: excluded.threadID, folder: "/outside", updatedAt: now, topic: "Out-of-scope excerpt")
        ]
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, insights: notes, now: now)
        XCTAssertEqual(snapshot.previews[codex.conversationKey], ConversationPreview(project: "Spleen", excerpt: "Compare suggested conversations.",
            timing: TurnTiming(lastCompletedAt: now.addingTimeInterval(-120), checkedAt: now)))
        XCTAssertEqual(snapshot.previews[claude.conversationKey], ConversationPreview())
        XCTAssertEqual(snapshot.previews[stale.conversationKey], ConversationPreview(project: "Spleen"))
        XCTAssertEqual(snapshot.previews[excluded.conversationKey], ConversationPreview())
    }

    func testFrontedConversationIsCurrentUntilANewerInteractionIsRecorded() throws {
        let a = Destination(title: "Codex A", threadID: "thr_fronted_a")
        let b = Destination(title: "Codex B", threadID: "thr_fronted_b")
        let claude = Destination(title: "Claude chat", threadID: "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef", provider: .claude)
        var state = SavedState(); state.destinations = [a, b, claude]
        var context = ContextMemory()
        context.record(ContextEvent(key: a.conversationKey, kind: .spleenDispatch, observedAt: now.addingTimeInterval(-120), source: "spleen", evidence: .spleenInteraction), now: now)
        context.record(ContextEvent(key: b.conversationKey, kind: .spleenDispatch, observedAt: now.addingTimeInterval(-10), source: "spleen", evidence: .spleenInteraction), now: now)
        // Returned to the Claude chat by hand; its visit dwell has not elapsed.
        context.foreground = ForegroundHint(key: claude.conversationKey, at: now.addingTimeInterval(-1))
        let fronted = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: context, now: now)
        XCTAssertEqual(fronted.currentKey, claude.conversationKey)
        XCTAssertEqual(fronted.previousKey, b.conversationKey)
        XCTAssertEqual(fronted.ordered.first, b, "the thread just left is the return target, not hidden as current")
        XCTAssertEqual(fronted.ordered.last, claude)
        XCTAssertTrue(fronted.subtitles[claude.conversationKey]?.hasSuffix("In front") == true, fronted.subtitles[claude.conversationKey] ?? "nil")
        // Another application in front: nothing is current, and the chat that would
        // have been hidden becomes the return target instead.
        context.frontApplication = .other
        let elsewhere = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: context, now: now)
        XCTAssertNil(elsewhere.currentKey)
        XCTAssertEqual(elsewhere.previousKey, claude.conversationKey)
        XCTAssertTrue(elsewhere.subtitles[claude.conversationKey]?.hasSuffix("Previous conversation") == true, elsewhere.subtitles[claude.conversationKey] ?? "nil")
        XCTAssertEqual(elsewhere.ordered.filter { $0.provider == .codex }, [b, a], "the recorded Codex order is unchanged")
        // Visited a Claude chat, then switched to Codex by hand with no Codex observation:
        // the Claude chat is not current, and is the return target instead of hidden.
        let visited = ContextMemory.resolveCurrent(recorded: claude.conversationKey, recordedAt: now.addingTimeInterval(-600),
            previous: b.conversationKey, foreground: nil, front: .provider(.codex), at: now)
        XCTAssertNil(visited.current); XCTAssertEqual(visited.previous, claude.conversationKey)
        XCTAssertEqual(ContextMemory.resolveCurrent(recorded: claude.conversationKey, recordedAt: now.addingTimeInterval(-600),
            previous: b.conversationKey, foreground: nil, front: .provider(.claude), at: now).current, claude.conversationKey)
        context.frontApplication = .provider(.claude)
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: CatalogCache(), context: context, now: now).currentKey, claude.conversationKey)
        context.frontApplication = nil
        // A foreground report older than the newest interaction is stale.
        context.foreground = ForegroundHint(key: claude.conversationKey, at: now.addingTimeInterval(-30))
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: CatalogCache(), context: context, now: now).currentKey, b.conversationKey)
        // Placement only: never persisted, never an interaction.
        context.foreground = ForegroundHint(key: claude.conversationKey, at: now)
        context.frontApplication = .provider(.codex)
        let decoded = try JSONDecoder().decode(ContextMemory.self, from: JSONEncoder().encode(context))
        XCTAssertNil(decoded.foreground); XCTAssertNil(decoded.frontApplication)
        XCTAssertEqual(context.currentHint(at: now)?.key, b.conversationKey)
        XCTAssertEqual(context.recentInteractions(at: now).map(\.key), [a.conversationKey, b.conversationKey])
    }

    func testTopicEvidenceChangesRelevanceWithoutChangingPinsOrLabels() throws {
        var state = SavedState()
        state.destinations = [Destination(title: "Pinned reference", threadID: "thr_pinned_123", pinned: true),
            Destination(title: "My current work", threadID: "thr_current_123", lastOpenedAt: now),
            Destination(title: "Unrelated recent", threadID: "thr_unrelated_123", lastOpenedAt: now.addingTimeInterval(-60))]
        var catalog = CatalogCache(); catalog.folders = ["/personal/app", "/personal/music"]
        catalog.entries = [CatalogEntry(id: "thr_current_123", title: "Provider title", folder: "/personal/app", updatedAt: now),
            CatalogEntry(id: "thr_unrelated_123", title: "Piano", folder: "/personal/music", updatedAt: now),
            CatalogEntry(id: "thr_related_123", title: "Earlier investigation", folder: "/personal/app", updatedAt: now.addingTimeInterval(-100)),
            CatalogEntry(id: "thr_other_123", title: "Sidebar colors", folder: "/personal/app", updatedAt: now)]
        let notes = [ThreadInsight(id: "thr_current_123", folder: "/personal/app", updatedAt: now, topic: "Fix SQLite write lock contention", nextStep: "Retry transactions after database lock"),
            ThreadInsight(id: "thr_related_123", folder: "/personal/app", updatedAt: now.addingTimeInterval(-100), topic: "SQLite contention investigation", decision: "Use serialized database transactions")]
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, insights: notes, now: now)
        XCTAssertEqual(snapshot.ordered.prefix(3).map(\.threadID), ["thr_unrelated_123", "thr_pinned_123", "thr_related_123"],
            "The stronger return preference puts the previous conversation ahead of topic matches; topic still orders the remaining choices")
        XCTAssertEqual(snapshot.ordered.last?.title, "My current work")
        XCTAssertEqual(snapshot.results(query: "serialized transactions").map(\.threadID), ["thr_related_123"])
        XCTAssertEqual(snapshot.subtitles[ConversationKey(provider: .codex, id: "thr_related_123")], "Codex · Related topic · app")
        XCTAssertTrue(RelevanceSnapshot(state: state, catalog: catalog, now: now).results(query: "serialized transactions").isEmpty)
        // With no selection history, preserve deterministic local update order and still search notes.
        state.clearRecents(); state.rememberRecents = false
        let cold = RelevanceSnapshot(state: state, catalog: catalog, insights: notes, now: now)
        XCTAssertEqual(cold.ordered.prefix(2).map(\.threadID), ["thr_current_123", "thr_pinned_123"])
        XCTAssertFalse(cold.subtitles.values.contains { $0.hasPrefix("Related topic") || $0.hasPrefix("Same project") })
    }
    func testSearchTitlePrecedenceAccentAndProjectTokens() {
        var state = SavedState()
        state.destinations = [Destination(title: "Other", threadID: "thr_other_123"), Destination(title: "Café", threadID: "thr_exact_123"),
            Destination(title: "Café migration", threadID: "thr_prefix_123"), Destination(title: "The café", threadID: "thr_substring_123")]
        var catalog = CatalogCache(); catalog.folders = ["/personal/backend"]
        catalog.entries = [CatalogEntry(id: "thr_other_123", title: "Provider", folder: "/personal/backend", updatedAt: now)]
        let notes = [ThreadInsight(id: "thr_other_123", folder: "/personal/backend", updatedAt: now, topic: "Café database")]
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, insights: notes, now: now)
        XCTAssertEqual(snapshot.results(query: "CAFE").map(\.threadID), ["thr_exact_123", "thr_prefix_123", "thr_substring_123", "thr_other_123"])
        XCTAssertEqual(snapshot.results(query: "backend database").map(\.threadID), ["thr_other_123"])
        XCTAssertTrue(snapshot.results(query: "backend missing").isEmpty)
    }
    func testExternalClaudeCodeTopicRanksCodexWithoutInventingSelectedCandidate() {
        var state = SavedState()
        state.destinations = [Destination(title: "Piano practice", threadID: "thr_piano_123", lastOpenedAt: now),
            Destination(title: "SQLite database transaction lock contention", threadID: "thr_sqlite_123")]
        var context = ContextMemory()
        let key = ConversationKey(provider: .claude, id: "desktop-code:local_fixture")
        context.record(ContextEvent(key: key, topic: "SQLite database transaction lock contention", kind: .selectedConversation,
            observedAt: now, source: "claude-accessibility", evidence: .observedSelection), now: now)
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: context, now: now)
        XCTAssertEqual(snapshot.ordered.first?.threadID, "thr_sqlite_123")
        XCTAssertEqual(snapshot.ordered.count, 2)
        XCTAssertTrue(snapshot.ordered.allSatisfy { $0.provider == .codex })
        XCTAssertFalse(snapshot.subtitles.values.contains { $0.contains("Last selected") })
        XCTAssertTrue(snapshot.subtitles[ConversationKey(provider: .codex, id: "thr_sqlite_123")]?.contains("Related topic") == true)

        var lifecycle = ContextMemory()
        lifecycle.record(ContextEvent(key: key, topic: "SQLite database transaction lock contention", kind: .turnCompleted,
            observedAt: now, source: "code-hook", evidence: .lifecycle), now: now)
        let unchanged = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: lifecycle, now: now)
        XCTAssertEqual(unchanged.ordered, RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now).ordered)
    }
    func testExternalUnknownTopicAvoidsOldSelectionAndRequiresAbsoluteProjectEvidence() {
        var state = SavedState()
        state.destinations = [Destination(title: "Previous", threadID: "thr_previous_123", lastOpenedAt: now),
                              Destination(title: "Project notes", threadID: "thr_project_123")]
        var catalog = CatalogCache(); catalog.folders = ["/app"]
        catalog.entries = [CatalogEntry(id: "thr_project_123", title: "Project notes", folder: "/app", updatedAt: now)]
        let key = ConversationKey(provider: .claude, id: "desktop-code:local_fixture")
        var context = ContextMemory()
        context.record(ContextEvent(key: key, project: "app", kind: .selectedConversation,
            observedAt: now, source: "claude-accessibility", evidence: .observedSelection), now: now)
        let relative = RelevanceSnapshot(state: state, catalog: catalog, context: context, now: now)
        XCTAssertEqual(relative.ordered.first?.threadID, "thr_previous_123")
        XCTAssertFalse(relative.subtitles.values.contains { $0.contains("Last selected") || $0.contains("Same project") })
        context.record(ContextEvent(key: key, project: "/app", kind: .selectedConversation,
            observedAt: now, source: "claude-accessibility", evidence: .observedSelection), now: now)
        let absolute = RelevanceSnapshot(state: state, catalog: catalog, context: context, now: now)
        XCTAssertEqual(absolute.ordered.first?.threadID, "thr_project_123")
        XCTAssertTrue(absolute.subtitles[ConversationKey(provider: .codex, id: "thr_project_123")]?.contains("Same project") == true)
    }
    func testScopeFreshnessAndHiddenRowsExcludeInsightText() {
        var catalog = CatalogCache(); catalog.folders = ["/allowed"]
        let allowed = CatalogEntry(id: "thr_allowed_123", title: "Allowed", folder: "/allowed", updatedAt: now)
        catalog.entries = [allowed, CatalogEntry(id: "thr_excluded_123", title: "Excluded", folder: "/excluded", updatedAt: now)]
        var cache = InsightCache()
        cache.entries = [ThreadInsight(id: allowed.id, folder: allowed.folder, updatedAt: now.addingTimeInterval(-1), topic: "STALE"),
            ThreadInsight(id: "thr_excluded_123", folder: "/excluded", updatedAt: now, topic: "PRIVATE")]
        let snapshot = RelevanceSnapshot(state: SavedState(), catalog: catalog, insights: cache.entries, now: now)
        XCTAssertTrue(snapshot.results(query: "STALE").isEmpty); XCTAssertTrue(snapshot.results(query: "PRIVATE").isEmpty)
        cache.retain(catalog: catalog); XCTAssertTrue(cache.entries.isEmpty)
        catalog.hiddenIDs = [allowed.id]
        XCTAssertTrue(RelevanceSnapshot(state: SavedState(), catalog: catalog, now: now).ordered.isEmpty)
    }
    func testSummaryExtractionSkipsToolsReasoningCommentaryAndEnvironment() throws {
        let entry = CatalogEntry(id: "thr_allowed_123", title: "Work", folder: "/allowed", updatedAt: now)
        let data = Data(#"{"data":[{"items":[{"type":"userMessage","content":[{"type":"text","text":"<environment_context>\nSECRET_ENV\n</environment_context>\nFix SQLite lock contention"}]},{"type":"reasoning","text":"SECRET_REASONING"},{"type":"commandExecution","command":"SECRET_COMMAND"},{"type":"agentMessage","phase":"commentary","text":"SECRET_PROGRESS"},{"type":"agentMessage","phase":"final_answer","text":"We decided to serialize transactions. Next step is benchmark lock contention."}]}]}"#.utf8)
        let note = try InsightDecoder.page(data, entry: entry)
        XCTAssertTrue(note.topic.hasPrefix("Fix SQLite lock contention"))
        XCTAssertEqual(note.decision, "We decided to serialize transactions")
        XCTAssertEqual(note.nextStep, "Next step is benchmark lock contention")
        XCTAssertFalse(note.text.contains("SECRET"))
        let metadata = Data(#"{"thread":{"id":"thr_allowed_123","cwd":"/allowed","updatedAt":2000000000}}"#.utf8)
        XCTAssertNoThrow(try InsightDecoder.validateMetadata(metadata, entry: entry, folders: ["/allowed"]))
        XCTAssertThrowsError(try InsightDecoder.validateMetadata(metadata, entry: entry, folders: ["/elsewhere"]))
        let changed = CatalogEntry(id: entry.id, title: entry.title, folder: entry.folder, updatedAt: now.addingTimeInterval(1))
        XCTAssertThrowsError(try InsightDecoder.validateMetadata(metadata, entry: changed, folders: ["/allowed"]))
    }
    func testShortFollowupRetainsPriorTopicAndCorruptCacheFallsBack() throws {
        let entry = CatalogEntry(id: "thr_allowed_123", title: "Work", folder: "/allowed", updatedAt: now)
        let data = Data(#"{"data":[{"items":[{"type":"userMessage","content":[{"type":"text","text":"yes, do it"}]}]},{"items":[{"type":"userMessage","content":[{"type":"text","text":"<environment_context>ignored</environment_context>\nInvestigate SQLite transaction lock contention"}]},{"type":"agentMessage","text":"We decided to serialize SQLite transactions."}]}]}"#.utf8)
        let note = try InsightDecoder.page(data, entry: entry)
        XCTAssertTrue(note.topic.contains("SQLite")); XCTAssertFalse(note.topic.contains("yes, do it")); XCTAssertFalse(note.text.contains("ignored"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{broken".utf8).write(to: url)
        XCTAssertThrowsError(try InsightCache.load(from: url))
        var cache = InsightCache(); cache.entries = [note]; try cache.save(to: url)
        XCTAssertEqual(try InsightCache.load(from: url).entries, [note])
    }
    func testGenerationAndFrozenPresentation() {
        var pipeline = RelevancePipeline(), first = SavedState(), second = SavedState()
        first.destinations = [Destination(title: "Old", threadID: "thr_old_123")]
        second.destinations = [Destination(title: "New", threadID: "thr_new_123")]
        let a = pipeline.begin(), b = pipeline.begin()
        XCTAssertTrue(pipeline.finish(RelevanceSnapshot(state: second, catalog: CatalogCache()), generation: b))
        let visible = pipeline.ready
        XCTAssertFalse(pipeline.finish(RelevanceSnapshot(state: first, catalog: CatalogCache()), generation: a))
        let c = pipeline.begin()
        XCTAssertTrue(pipeline.finish(RelevanceSnapshot(state: first, catalog: CatalogCache()), generation: c))
        XCTAssertEqual(visible.results(query: "new").count, 1)
        XCTAssertTrue(visible.results(query: "old").isEmpty)
        XCTAssertEqual(pipeline.ready.ordered.first?.title, "Old")
    }
    func testCachedOpeningAndSearchAtThousandThreads() {
        var state = SavedState(), catalog = CatalogCache()
        catalog.folders = ["/project"]
        var notes: [ThreadInsight] = []
        for i in 0..<1000 {
            let id = "thr_fixture_\(i)"
            state.destinations.append(Destination(title: "Chat \(i)", threadID: id))
            catalog.entries.append(CatalogEntry(id: id, title: "Chat \(i)", folder: "/project", updatedAt: now))
            notes.append(ThreadInsight(id: id, folder: "/project", updatedAt: now, topic: "SQLite lock transactions diagnostic \(i)"))
        }
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, insights: notes, now: now)
        var open: [Double] = [], search: [Double] = [], count = 0
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            let visible = snapshot; count += visible.results(query: "").count
            open.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let typed = ProcessInfo.processInfo.systemUptime
            count += visible.results(query: "Chat 99").count
            search.append((ProcessInfo.processInfo.systemUptime - typed) * 1000)
        }
        open.sort(); search.sort()
        XCTAssertEqual(count, 101_900)
        XCTAssertEqual(snapshot.results(query: "Chat 99").prefix(11).count, 11)
        XCTAssertLessThan(open[94], 5); XCTAssertLessThan(search[94], 20)
        print(String(format: "Immutable relevance snapshot, 1000 threads / 100 samples: cached opening p95 %.3f ms; search p95 %.3f ms", open[94], search[94]))
    }
}
