import Foundation
import SpleenCore

/// Offline integration fixtures: no windows, permission requests, provider process, or network transport.
func runReadinessTests() -> (passed: Int, failures: [String]) {
    var count = 0, failures: [String] = []
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-readiness-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    @discardableResult func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return condition()
    }
    let instant = Date(timeIntervalSince1970: 2_000_000_000)
    let prior = Destination(title: "Piano practice", threadID: "thr_readiness_piano", lastOpenedAt: instant)
    let related = Destination(title: "SQLite database transaction lock contention", threadID: "thr_readiness_sqlite")
    var state = SavedState(); state.destinations = [prior, related]
    let selection = ContextEvent(key: ConversationKey(provider: .claude, id: "desktop-code:local_fixture"),
        topic: "SQLite database transaction lock contention", kind: .selectedConversation,
        observedAt: instant, source: "offline-fixture", evidence: .observedSelection)
    var memory = ContextMemory(); memory.record(selection, now: instant)

    let prepared = PreparedContext(state: state, catalog: CatalogCache(), context: memory, now: instant, uptime: 100)
    let frozen = prepared.snapshot(now: instant, uptime: 100)
    check(frozen.ordered.first?.id == related.id, "fresh external topic informs prepared local order")
    check(prepared.snapshot(now: instant.addingTimeInterval(1801), uptime: 101).ordered.first?.id == prior.id,
          "sleep-sized wall advance expires context despite minimal uptime advance")
    check(prepared.snapshot(now: instant.addingTimeInterval(100), uptime: 1901).ordered.first?.id == prior.id,
          "monotonic expiry prevents a wall adjustment from extending context")
    check(prepared.snapshot(now: instant.addingTimeInterval(-1), uptime: 101).ordered.first?.id == prior.id,
          "backwards wall clock fails closed to prepared neutral order")
    check(frozen.ordered.first?.id == related.id, "an invocation snapshot remains frozen after source expiry")

    do {
        let visitsDirectory = directory.appendingPathComponent("claude-visits")
        let visitsRepository = StateRepository(url: visitsDirectory.appendingPathComponent("state.json"))
        try visitsRepository.save(SavedState())
        let visitsStore = ContextRepository(url: visitsDirectory.appendingPathComponent("context.json"))
        let visitA = ConversationKey(provider: .claude, id: "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef")
        let visitB = ConversationKey(provider: .claude, id: "desktop-code:local_11234567-89ab-cdef-0123-456789abcdef")
        let visitsClock = ReadinessClock(wall: instant, uptime: 100)
        func visit(_ key: ConversationKey, title: String, at date: Date) throws {
            try visitsStore.record(ContextEvent(key: key, topic: title, kind: .selectedConversation,
                observedAt: date, source: "claude-desktop-accessibility", evidence: .observedSelection), now: date)
        }
        try visit(visitA, title: "Same title", at: instant)
        let visits = AppModel(repository: visitsRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
            now: { visitsClock.wall }, uptime: { visitsClock.uptime })
        check(wait { !visits.indexing }, "visited Claude session restores from bounded context on startup")
        visits.prepare()
        let firstVisit = visits.results.first!
        check(firstVisit.conversationKey == visitA && firstVisit.lastOpenedAt == nil,
              "observed Claude visit is navigable without inventing a Spleen dispatch timestamp")
        let originalChoices = visits.compassItems, originalSelection = visits.selectedID
        visitsClock.wall = instant.addingTimeInterval(1)
        try visit(visitB, title: "Same title", at: visitsClock.wall)
        check(wait { visits.context.currentHint(at: visitsClock.wall)?.key == visitB && !visits.indexing },
              "new foreground Claude observation refreshes prepared candidates")
        check(visits.compassItems == originalChoices && visits.selectedID == originalSelection && visits.updateReady,
              "Claude observation cannot move an open compass")
        visits.endPresentation(); visits.prepare()
        check(Set(visits.results.map(\.conversationKey)) == Set([visitA, visitB]) && Set(visits.results.map(\.id)).count == 2,
              "duplicate Claude titles remain distinct choices on next opening")
        visits.beginSearch("Same")
        let frozenSearch = visits.results
        visitsClock.wall = instant.addingTimeInterval(2)
        try visit(visitB, title: "Renamed session", at: visitsClock.wall)
        check(wait { visits.context.currentHint(at: visitsClock.wall)?.topic == "Renamed session" && !visits.indexing },
              "Claude rename refresh completes off the opening path")
        check(visits.results == frozenSearch && visits.query == "Same", "typed Claude search remains frozen during a rename")
        visits.acceptedDispatch(firstVisit.id)
        check(visits.state.destinations.isEmpty && visits.context.events.contains { $0.key == visitA && $0.kind == .spleenDispatch && $0.evidence == .spleenInteraction },
              "unsaved Claude dispatch records intent without permanently saving the recent")
        check(wait { !visits.indexing }, "Claude dispatch preparation settles")
        visits.endPresentation(); visits.prepare()
        visits.edit(visits.results.first { $0.conversationKey == visitA })
        check(visits.editorCanRemove && visits.editorID == nil, "an unsaved visited Claude session can be removed")
        visits.removeEdited()
        check(wait { !visits.indexing && visits.catalogPersistencePending == 0 }, "Claude hide persists and rebuilds")
        check(!visits.results.contains { $0.conversationKey == visitA } && visits.hasHiddenChats,
              "removed Claude visit cannot immediately reappear from observation memory")
        let restored = AppModel(repository: visitsRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
            now: { visitsClock.wall }, uptime: { visitsClock.uptime })
        check(wait { !restored.indexing }, "visited-session restart fixture prepares")
        check(!restored.results.contains { $0.conversationKey == visitA } && restored.results.contains { $0.conversationKey == visitB },
              "hidden Claude visit and surviving rename persist across restart")
        visits.restoreHiddenChats()
        check(wait { !visits.indexing && visits.catalogPersistencePending == 0 }, "restoring hidden Claude visits settles")
        check(visits.results.contains { $0.conversationKey == visitA }, "restore action makes retained Claude visit available")
        visits.clearRecents()
        check(wait { !visits.indexing && visits.results.isEmpty && (try? visitsStore.load().events.isEmpty) == true },
              "clear recents removes unsaved Claude destinations from memory and disk")
        visits.showSettings(); visits.rememberDraft = false; visits.saveSettings()
        check(wait { !visits.indexing && (try? visitsStore.load().recentsEnabled) == false },
              "disabling recents persists empty Claude candidate memory")

        let burstDirectory = directory.appendingPathComponent("coalesced-builds")
        let burstRepository = StateRepository(url: burstDirectory.appendingPathComponent("state.json"))
        var burstState = SavedState()
        burstState.destinations = [Destination(title: "Saved baseline", threadID: "thr_readiness_stable")]
        try burstRepository.save(burstState)
        var burstCatalog = CatalogCache(); burstCatalog.folders = ["/burst"]; burstCatalog.refreshedAt = Date()
        try burstCatalog.save(to: burstDirectory.appendingPathComponent("catalog.json"))
        let builder = ReadinessSnapshotFixture(), burstPrediction = ReadinessPredictionFixture()
        let burst = AppModel(repository: burstRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
            rankingTransport: burstPrediction, catalogWriter: { _, _ in }, snapshotBuilder: builder.build)
        check(wait { !burst.indexing }, "coalescing fixture prepares its baseline")
        burst.prepare()
        let frozenChoices = burst.compassItems, frozenSelection = burst.selectedID
        builder.blockNext()
        func burstEntry(_ version: Int) -> CatalogEntry {
            CatalogEntry(id: "thr_readiness_burst", title: String(format: "Version %03d", version), folder: "/burst", updatedAt: instant)
        }
        burst.acceptCatalog(entries: [burstEntry(0)], truncated: false)
        check(wait { builder.calls == 2 }, "one obsolete build is deliberately held in progress")
        for version in 1...32 { burst.acceptCatalog(entries: [burstEntry(version)], truncated: false) }
        builder.release.signal()
        check(wait { !burst.indexing && burst.catalogPersistencePending == 0 }, "latest generation finishes after a catalog burst")
        check(builder.calls == 3 && burst.snapshotBuildCount == 3 && builder.lastCatalogTitle == "Version 032",
              "32 waiting generations coalesce into one latest build behind the running build")
        check(burstPrediction.calls == 1, "superseded builds never initiate prediction work")
        check(burst.compassItems == frozenChoices && burst.selectedID == frozenSelection && burst.updateReady,
              "coalesced publication preserves the open invocation")
        burst.endPresentation(); burst.prepare()
        check(burst.results.contains { $0.title == "Version 032" } && !burst.results.contains { $0.title == "Version 000" },
              "next invocation adopts only the latest burst result")

        builder.blockNext()
        var edited = burst.state; edited.destinations[0].title = "Edited saved label"
        check(burst.commit(edited), "explicit edit queues a presentation-scoped update")
        check(wait { builder.calls == 4 }, "explicit edit build is held before publication")
        burst.endPresentation(); burst.prepare()
        let reopenedChoices = burst.compassItems, reopenedSelection = burst.selectedID
        builder.release.signal()
        check(wait { !burst.indexing }, "edit completes after a different invocation begins")
        check(burst.compassItems == reopenedChoices && burst.selectedID == reopenedSelection && burst.updateReady,
              "adoption requested by an older invocation cannot move a reopened compass")
        burst.endPresentation(); burst.prepare()
        check(burst.results.contains { $0.title == "Edited saved label" }, "following invocation receives completed edit")
        burst.endPresentation()

        let manyRepository = StateRepository(url: directory.appendingPathComponent("direct-opening/state.json"))
        var manyState = SavedState()
        manyState.destinations = (0..<1000).map {
            Destination(title: String(format: "Chat %04d", $0), threadID: "thr_readiness_many_\($0)")
        }
        try manyRepository.save(manyState)
        let many = AppModel(repository: manyRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !many.indexing }, "1000-chat opening fixture is prepared")
        many.prepare(); many.beginSearch("0999")
        let refreshesBeforeOpen = many.resultRefreshCount, buildsBeforeOpen = many.snapshotBuildCount
        many.endPresentation(); many.prepare()
        check(many.query.isEmpty && many.results.count == 1000 && many.selectedID == many.compassItems.first?.id &&
              many.resultRefreshCount == refreshesBeforeOpen,
              "opening directly installs prepared choices and center without rebuilding the prior typed query")
        var openingSamples: [Double] = []
        for _ in 0..<100 {
            many.selectedID = many.results.last?.id
            many.endPresentation(); many.prepare()
            openingSamples.append(many.prepareMilliseconds)
        }
        openingSamples.sort()
        check(many.resultRefreshCount == refreshesBeforeOpen && many.snapshotBuildCount == buildsBeforeOpen,
              "100 direct openings do not scan previous tail selection or rebuild results")
        check(openingSamples[94] < 5, "1000-chat direct opening stays below 5 ms at p95")
        print(String(format: "Prepared AppModel opening, 1000 chats / 100 samples: median %.3f ms; p95 %.3f ms; max %.3f ms", openingSamples[50], openingSamples[94], openingSamples[99]))
        many.endPresentation()

        let discovered = [CatalogEntry(id: "thr_readiness_first_a", title: "First discovered chat", folder: "/new/project", updatedAt: instant),
                          CatalogEntry(id: "thr_readiness_first_b", title: "SQLite investigation", folder: "/new/project", updatedAt: instant)]
        let coldRepository = StateRepository(url: directory.appendingPathComponent("cold-discovery/state.json"))
        let coldFetch = ReadinessCatalogFixture(entries: discovered, delayFirst: true)
        let cold = AppModel(repository: coldRepository, insightFetcher: { _, _ in [] }, discoveryFetcher: coldFetch.fetch)
        check(wait { !cold.indexing && cold.catalogPersistencePending == 0 }, "cold startup completes an empty cached snapshot first")
        cold.prepare()
        check(wait { coldFetch.calls == 1 }, "cold opening starts delayed automatic discovery")
        check(cold.compassItems.isEmpty && cold.selectedID == nil, "cold invocation starts with no available choices")
        coldFetch.release.signal()
        check(wait { !cold.refreshing && !cold.indexing && cold.catalogPersistencePending == 0 }, "first delayed catalog and index finish")
        check(cold.compassItems.count == 2 && cold.results.count == 2 && cold.selectedID == cold.compassItems.first?.id && !cold.updateReady,
              "first discovered choices fill an untouched empty compass without reopening")
        cold.endPresentation()

        let typedFetch = ReadinessCatalogFixture(entries: discovered, delayFirst: true)
        let typed = AppModel(repository: StateRepository(url: directory.appendingPathComponent("typed-discovery/state.json")),
                             insightFetcher: { _, _ in [] }, discoveryFetcher: typedFetch.fetch)
        check(wait { !typed.indexing && typed.catalogPersistencePending == 0 }, "typed-search fixture finishes empty cached startup")
        typed.prepare(); typed.beginSearch("SQLite")
        check(wait { typedFetch.calls == 1 }, "typed-search fixture starts delayed discovery")
        typedFetch.release.signal()
        check(wait { !typed.refreshing && !typed.indexing && typed.catalogPersistencePending == 0 }, "typed-search discovery finishes")
        check(typed.query == "SQLite" && typed.results.isEmpty && typed.selectedID == nil && typed.updateReady,
              "discovery preserves an empty invocation once the person has typed a query")
        typed.endPresentation(); typed.prepare()
        check(typed.compassItems.count == 2, "typed invocation can adopt discovered choices on the next opening")
        typed.endPresentation()

        let existingDirectory = directory.appendingPathComponent("nonempty-discovery")
        let existingRepository = StateRepository(url: existingDirectory.appendingPathComponent("state.json"))
        var existingState = SavedState(); existingState.destinations = [prior]
        try existingRepository.save(existingState)
        var automatic = CatalogCache(); automatic.version = 2; automatic.policy = DiscoveryPolicy()
        try automatic.save(to: existingDirectory.appendingPathComponent("catalog.json"))
        let existingFetch = ReadinessCatalogFixture(entries: discovered, delayFirst: true)
        let existing = AppModel(repository: existingRepository, insightFetcher: { _, _ in [] }, discoveryFetcher: existingFetch.fetch)
        check(wait { !existing.indexing }, "nonempty fixture finishes cached startup")
        existing.prepare()
        let existingChoices = existing.compassItems, existingSelection = existing.selectedID
        check(wait { existingFetch.calls == 1 }, "nonempty fixture starts delayed discovery")
        existingFetch.release.signal()
        check(wait { !existing.refreshing && !existing.indexing && existing.catalogPersistencePending == 0 }, "nonempty discovery finishes")
        check(existing.compassItems == existingChoices && existing.results == existingChoices && existing.selectedID == existingSelection && existing.updateReady,
              "first discovery never moves existing invocation choices or selection")
        existing.endPresentation()

        let ttlDirectory = directory.appendingPathComponent("cache-ttl")
        let ttlRepository = StateRepository(url: ttlDirectory.appendingPathComponent("state.json"))
        try ttlRepository.save(SavedState())
        var ttlCache = CatalogCache(); ttlCache.folders = ["/new/project"]; ttlCache.entries = discovered; ttlCache.refreshedAt = instant
        try ttlCache.save(to: ttlDirectory.appendingPathComponent("catalog.json"))
        let ttlClock = ReadinessClock(wall: instant, uptime: 100)
        let ttlFetch = ReadinessCatalogFixture(entries: discovered)
        let ttl = AppModel(repository: ttlRepository, insightFetcher: { _, _ in [] }, discoveryFetcher: ttlFetch.fetch,
                           now: { ttlClock.wall }, uptime: { ttlClock.uptime })
        check(wait { !ttl.indexing }, "TTL fixture reads persisted cache")
        ttl.prepare()
        var openingRefreshChecked = false
        DispatchQueue.main.async { openingRefreshChecked = true }
        check(wait { openingRefreshChecked }, "fresh-cache opening schedules its refresh decision")
        check(ttlFetch.calls == 0 && !ttl.refreshing, "persisted fresh cache avoids provider startup on opening")
        ttl.endPresentation()
        ttlClock.wall = instant.addingTimeInterval(301)
        ttl.refreshCatalog()
        check(wait { ttlFetch.calls == 1 && !ttl.refreshing }, "expired cache triggers one provider refresh")
        ttl.refreshCatalog()
        check(ttlFetch.calls == 1 && !ttl.refreshing, "repeat refresh respects fresh cache and attempt backoff")
        ttl.refreshCatalog(force: true)
        check(wait { ttlFetch.calls == 2 && !ttl.refreshing }, "explicit force bypasses cache lifetime and attempt backoff")
        ttlFetch.setFailure(true)
        ttlClock.wall = instant.addingTimeInterval(602)
        ttl.refreshCatalog()
        check(wait { ttlFetch.calls == 3 && !ttl.refreshing }, "expired-cache failure completes without renewing cache freshness")
        ttl.refreshCatalog()
        check(ttlFetch.calls == 3 && !ttl.refreshing, "failed refresh remains throttled while cache is stale")
        ttl.refreshCatalog(force: true)
        check(wait { ttlFetch.calls == 4 && !ttl.refreshing }, "force bypasses failed-attempt backoff")
        ttlClock.wall = instant.addingTimeInterval(-1)
        ttl.refreshCatalog()
        check(wait { ttlFetch.calls == 5 && !ttl.refreshing }, "backwards wall time cannot permanently suppress cache refresh")
        check(wait { ttl.catalogPersistencePending == 0 }, "TTL fixture persistence settles")

        let repository = StateRepository(url: directory.appendingPathComponent("expiry/state.json"))
        try repository.save(state)
        let contextStore = ContextRepository(url: repository.url.deletingLastPathComponent().appendingPathComponent("context.json"))
        try contextStore.record(selection, now: instant)
        let clock = ReadinessClock(wall: instant, uptime: 100)
        let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
                             now: { clock.wall }, uptime: { clock.uptime })
        check(wait { !model.indexing }, "offline context index finishes")
        let buildCount = model.snapshotBuildCount
        model.prepare()
        check(model.compassItems.first?.id == related.id, "opening adopts fresh prepared topic")
        clock.wall = instant.addingTimeInterval(1801); clock.uptime = 101
        model.beginSearch()
        check(model.results.first?.id == related.id, "expiry cannot move an open invocation")
        model.endPresentation(); model.prepare()
        check(model.compassItems.first?.id == prior.id, "next opening uses cached fallback after sleep")
        for _ in 0..<100 { model.endPresentation(); model.prepare() }
        check(model.snapshotBuildCount == buildCount && model.catalogPersistencePending == 0,
              "100 opens use cached values without indexing or cache persistence")
        model.endPresentation()

        // Restore a fresh fixture and overflow the audit log with lifecycle-only activity.
        clock.wall = instant; clock.uptime = 100
        let lastEvent = ContextEvent(key: prior.conversationKey, kind: .turnCompleted,
                                    observedAt: instant, source: "offline-lifecycle-79", evidence: .lifecycle)
        for index in 0..<80 {
            try contextStore.record(ContextEvent(key: prior.conversationKey, kind: .turnCompleted,
                observedAt: instant, source: "offline-lifecycle-\(index)", evidence: .lifecycle), now: instant)
        }
        check(wait { model.context.events.contains(lastEvent) && !model.indexing }, "lifecycle burst updates retained audit metadata")
        check(model.snapshotBuildCount == buildCount, "lifecycle burst and observed-event audit eviction do not rebuild relevance")
        check(model.context.currentHint(at: instant)?.key == selection.key, "audit burst preserves actual interaction memory")

        let predictionDirectory = directory.appendingPathComponent("prediction")
        let predictionRepository = StateRepository(url: predictionDirectory.appendingPathComponent("state.json"))
        var predictionState = SavedState()
        predictionState.destinations = (0..<3).map { Destination(title: "Alpha \($0)", threadID: "thr_readiness_predict_\($0)") }
        try predictionRepository.save(predictionState)
        var cache = CatalogCache(); cache.folders = ["/allowed"]
        cache.entries = [CatalogEntry(id: predictionState.destinations[0].threadID, title: "Provider title", folder: "/allowed", updatedAt: instant)]
        try cache.save(to: predictionDirectory.appendingPathComponent("catalog.json"))
        let transport = ReadinessPredictionFixture()
        let predicted = AppModel(repository: predictionRepository, catalogFetcher: { _ in (cache.entries, false) },
            insightFetcher: { _, _ in [] }, rankingTransport: transport, now: { instant }, uptime: { 100 })
        check(wait { !predicted.indexing && transport.calls == 1 }, "offline prediction fixture gets one prepared request")
        try transport.complete(choice: 2, count: 3)
        check(wait { predicted.results.first?.id == predictionState.destinations[2].id }, "offline prediction becomes ready")
        cache.entries[0].updatedAt = instant.addingTimeInterval(1)
        predicted.acceptCatalog(entries: cache.entries, truncated: false)
        check(wait { !predicted.indexing }, "catalog metadata change completes background rebuild")
        check(predicted.results.first?.id == predictionState.destinations[2].id && transport.calls == 1,
              "semantically unchanged enriched input preserves cached prediction and request cap")
        let beforeFiltered = predicted.snapshotBuildCount
        predicted.acceptCatalog(entries: cache.entries + [CatalogEntry(id: "thr_readiness_excluded", title: "Excluded", folder: "/excluded", updatedAt: instant)], truncated: false)
        check(predicted.snapshotBuildCount == beforeFiltered, "excluded metadata does not count as a catalog change")
        check(wait { predicted.catalogPersistencePending == 0 }, "prediction fixture cache writes settle")

        let writerDirectory = directory.appendingPathComponent("writer")
        let writerRepository = StateRepository(url: writerDirectory.appendingPathComponent("state.json"))
        try writerRepository.save(SavedState())
        var writerCache = CatalogCache(); writerCache.folders = ["/allowed"]
        try writerCache.save(to: writerDirectory.appendingPathComponent("catalog.json"))
        let writer = ReadinessWriterFixture()
        let writing = AppModel(repository: writerRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
            catalogWriter: { value, url in try writer.write(value, to: url) })
        check(wait { !writing.indexing }, "cache writer fixture starts from cached state")
        writing.acceptCatalog(entries: [CatalogEntry(id: "thr_readiness_cached", title: "Cached", folder: "/allowed", updatedAt: instant)], truncated: false)
        check(wait { writer.started == 1 }, "catalog encoding and persistence are staged on the writer queue")
        writing.removeCatalogFolder("/allowed")
        let writesBeforeOpen = writer.started
        writing.prepare()
        check(writer.started == writesBeforeOpen && writing.catalogPersistencePending >= 2,
              "opening remains available while ordered cache writes are blocked")
        writing.endPresentation()
        writer.release.signal()
        check(wait { writing.catalogPersistencePending == 0 && !writing.indexing }, "ordered cache writes finish")
        let savedCatalog = try CatalogCache.load(from: writerDirectory.appendingPathComponent("catalog.json"))
        check(savedCatalog.folders.isEmpty && savedCatalog.entries.isEmpty && writer.folders == [["/allowed"], []],
              "later scope removal wins over an earlier staged catalog refresh")
        check(!writer.usedMainThread, "catalog writer never runs on the main thread")

        let corruptCatalog = directory.appendingPathComponent("corrupt-catalog.json")
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: corruptCatalog)
        do { try CatalogPersistence.write(CatalogCache(), to: corruptCatalog); check(false, "corrupt catalog must reject replacement") }
        catch {
            let remaining = try Data(contentsOf: corruptCatalog)
            check(remaining == corruptBytes, "corrupt catalog bytes are preserved")
        }

        let corruptDirectory = directory.appendingPathComponent("corrupt-state")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptRepository = StateRepository(url: corruptDirectory.appendingPathComponent("state.json"))
        try corruptBytes.write(to: corruptRepository.url)
        let settings = Data(#"{"observeClaudeDesktop":true}"#.utf8)
        try settings.write(to: corruptDirectory.appendingPathComponent("context-settings.json"))
        let preservedContext = ContextRepository(url: corruptDirectory.appendingPathComponent("context.json"))
        try preservedContext.record(selection, now: instant)
        let contextBytes = try Data(contentsOf: preservedContext.url)
        let failed = AppModel(repository: corruptRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !failed.indexing && failed.claudeContextStatus.contains("repair") }, "corrupt destinations fail closed before observer startup")
        check(!failed.state.rememberRecents && !failed.context.recentsEnabled && failed.context.events.isEmpty,
              "corrupt destinations cannot re-enable recents from defaults or old observer settings")
        failed.clearRecents()
        let remainingState = try Data(contentsOf: corruptRepository.url), remainingContext = try Data(contentsOf: preservedContext.url)
        check(remainingState == corruptBytes && remainingContext == contextBytes,
              "failed startup and clear action preserve destination and context stores")
        let remainingSettings = try Data(contentsOf: corruptDirectory.appendingPathComponent("context-settings.json"))
        check(remainingSettings == settings,
              "failed startup preserves observer preference file without acting on it")
    } catch { check(false, "readiness fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}

private final class ReadinessClock {
    var wall: Date
    var uptime: TimeInterval
    init(wall: Date, uptime: TimeInterval) { self.wall = wall; self.uptime = uptime }
}

private final class ReadinessSnapshotFixture {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    private var blockedCall: Int?
    private var catalogTitle: String?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var lastCatalogTitle: String? { lock.lock(); defer { lock.unlock() }; return catalogTitle }
    func blockNext() { lock.lock(); blockedCall = count + 1; lock.unlock() }
    func build(_ state: SavedState, _ catalog: CatalogCache, _ notes: [ThreadInsight], _ memory: ContextMemory,
               _ instant: Date, _ tick: TimeInterval, _ attention: SessionAttention) -> PreparedContext {
        lock.lock(); count += 1; let blocked = count == blockedCall; catalogTitle = catalog.entries.first?.title; lock.unlock()
        if blocked { _ = release.wait(timeout: .now() + 4) }
        return PreparedContext(state: state, catalog: catalog, insights: notes, context: memory, now: instant, uptime: tick)
    }
}

private final class ReadinessCatalogFixture {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let entries: [CatalogEntry]
    private let delayFirst: Bool
    private var count = 0
    private var fails = false
    private enum FixtureError: Error { case unavailable }
    init(entries: [CatalogEntry], delayFirst: Bool = false) { self.entries = entries; self.delayFirst = delayFirst }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setFailure(_ value: Bool) { lock.lock(); fails = value; lock.unlock() }
    func fetch(_ policy: DiscoveryPolicy) throws -> (entries: [CatalogEntry], truncated: Bool) {
        lock.lock(); count += 1; let delayed = delayFirst && count == 1, failed = fails; lock.unlock()
        if delayed { _ = release.wait(timeout: .now() + 4) }
        if failed { throw FixtureError.unavailable }
        return (entries, false)
    }
}

private final class ReadinessWriterFixture {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [[String]] = []
    private var onMain = false
    var started: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var folders: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func write(_ value: CatalogCache, to url: URL) throws {
        lock.lock(); values.append(value.folders); onMain = onMain || Thread.isMainThread
        let first = values.count == 1; lock.unlock()
        if first { _ = release.wait(timeout: .now() + 4) }
        try CatalogPersistence.write(value, to: url)
    }
}

private final class ReadinessPredictionFixture: DecisionsTransport {
    private(set) var calls = 0
    private var completion: ((Result<Data, Error>) -> Void)?
    func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
        calls += 1; self.completion = completion
        return {}
    }
    func complete(choice: Int, count: Int) throws {
        let probabilities: [[String: Any]] = (0..<count).map {
            ["value": "c\($0)", "probability": $0 == choice ? 0.9 : 0.0]
        } + [["value": "none", "probability": 0.1]]
        let data = try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "next_chat",
            "choice": "c\(choice)", "confidence": 0.9, "probabilities": probabilities]]])
        completion?(.success(data)); completion = nil
    }
}
