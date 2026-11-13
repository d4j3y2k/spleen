import AppKit
import SpleenCore

// Runs inside the built application, with a temporary store and injected dispatch/focus callbacks.
// It never sends synthetic input to another app or claims external desktop arrival.
func runAppTests() -> Bool {
    var failures: [String] = []
    var count = 0
    var models: [AppModel] = []
    func settle() {
        let deadline = Date().addingTimeInterval(3)
        while models.contains(where: { $0.indexing }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
    }
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        settle()
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    check(installedCodexCatalogClient(applicationURL: URL(fileURLWithPath: "/fixture/Applications/My Codex.app"))
        .executable.path == "/fixture/Applications/My Codex.app/Contents/Resources/codex-cli/bin/codex",
          "catalog helper follows a renamed or relocated Desktop installation")
    check(installedCodexCatalogClient(applicationURL: nil).executable == CodexCatalogClient().executable,
          "missing Desktop registration keeps the conventional install fallback")
    check(spleenDataDirectory(["Spleen", "--search-handoff-launch"], rememberedDirectory: "/fixture/previous").path == "/fixture/previous", "cold handoff preserves the last data directory")
    check(spleenDataDirectory(["Spleen", "--search-handoff-launch", "--data-dir", "/fixture/explicit"], rememberedDirectory: "/fixture/previous").path == "/fixture/explicit", "explicit data directory wins over handoff memory")
    check(spleenDataDirectory(["Spleen"], rememberedDirectory: "/fixture/previous").path == "/fixture/previous", "ordinary app launch also preserves the last data directory")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-app-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let model = AppModel(repository: StateRepository(url: temporary.appendingPathComponent("state.json")),
                         catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    models.append(model)
    model.edit(); model.editorTitle = "Local test chat"; model.editorLink = "01234567-89ab-cdef-0123-456789abcdef"; model.saveEditor()
    check(model.state.destinations.count == 1, "editor saves destination")
    let controller = PanelController(model: model)
    let own = ProcessInfo.processInfo.processIdentifier
    controller.currentPID = { own }
    var restored: [Int32] = []
    controller.restorePID = { restored.append($0) }
    var urls: [URL] = []
    controller.dispatchURL = { urls.append($0); return true }
    for _ in 0..<25 {
        controller.toggle()
        check(controller.panel.isVisible && controller.session.isPresented, "toggle presents panel")
        controller.toggle()
        check(!controller.panel.isVisible && !controller.session.isPresented, "toggle dismisses panel")
    }
    controller.present()
    controller.panel.makeFirstResponder(controller.panel.contentView)
    check(controller.panel.canBecomeKey && !controller.panel.canBecomeMain, "panel key/main policy")
    let compassSize = CompassLayout.size
    let small = NSRect(x: 0, y: 0, width: 1024, height: 550) // 13-inch "Larger Text" below the menu bar
    let lifted = { (frame: NSRect) in NSPoint(x: frame.midX - compassSize.width / 2, y: frame.midY - compassSize.height / 2 + 50) }
    let clamped = PanelController.clamp(lifted(small), size: compassSize, in: small)
    check(clamped.x == small.minX && clamped.y + compassSize.height == small.maxY, "an oversized panel keeps its top-left corner on screen")
    let roomy = NSRect(x: 0, y: 0, width: 2560, height: 1400)
    check(PanelController.clamp(lifted(roomy), size: compassSize, in: roomy) == lifted(roomy), "a panel that fits keeps its lifted center")
    controller.currentPID = { 101 }
    controller.dismiss(.cancel)
    controller.present()
    controller.currentPID = { own }
    controller.dismiss(.cancel)
    check(restored == [101], "cancel restores captured app through callback")
    restored.removeAll()
    controller.currentPID = { 101 }; controller.present()
    controller.currentPID = { 202 }; controller.dismiss(.cancel)
    check(restored.isEmpty, "cancel avoids restoring over a different app")
    controller.currentPID = { 101 }; controller.present(); controller.dismiss(.focusLoss)
    check(restored.isEmpty, "focus-loss dismissal does not reactivate")
    controller.present(); model.openSelected(); model.openSelected()
    check(urls.count == 1 && urls[0].absoluteString == "codex://threads/01234567-89ab-cdef-0123-456789abcdef", "canonical dispatch and double-open guard")
    check(restored.isEmpty && !controller.panel.isVisible, "dispatch hides without restoring prior app")
    check(model.state.destinations[0].lastOpenedAt != nil, "accepted dispatch updates recency")
    model.clearRecents()
    controller.dispatchURL = { _ in false }
    controller.present(); model.openSelected()
    check(controller.panel.isVisible && model.error != nil, "failed dispatch reopens with error")
    check(model.state.destinations[0].lastOpenedAt == nil, "failed dispatch not remembered")
    controller.dismiss(.cancel)
    model.edit(model.state.destinations[0]); model.editorTitle = "Renamed"; model.saveEditor()
    check(model.results.first?.title == "Renamed", "editor updates cached results")
    model.query = "missing"; check(model.results.isEmpty && model.selectedID == nil, "empty search clears selection")
    model.query = "ren"; check(model.selectedID == model.results.first?.id, "search selects matching result")
    model.edit(model.state.destinations[0]); model.removeEdited()
    check(model.state.destinations.isEmpty, "editor removes destination")
    let loaded = try? model.repository.load()
    check(loaded?.destinations.isEmpty == true, "removal persists")
    model.query = ""
    model.edit(); model.editorTitle = "First"; model.editorLink = "thr_first_test"; model.saveEditor()
    model.edit(); model.editorTitle = "Second"; model.editorLink = "thr_second_test"; model.saveEditor()
    settle(); model.prepare(); model.move(1)
    check(model.selectedID == model.results[1].id, "down selects next destination")
    model.move(1)
    check(model.selectedID == model.results[1].id, "down clamps at last destination")
    model.move(-1)
    check(model.selectedID == model.results[0].id, "up selects previous destination")
    model.edit(); model.editorTitle = "Invalid"; model.editorLink = "codex://threads/new"; model.saveEditor()
    check(model.mode == .editor && model.state.destinations.count == 2 && model.error != nil, "invalid editor input is retained for correction without saving")
    // A provider completion must not change the currently selected row or search corpus.
    let catalogModel = AppModel(repository: StateRepository(url: temporary.appendingPathComponent("catalog-state.json")), catalogFetcher: { _ in throw CatalogError.unavailable }, insightFetcher: { _, _ in [] })
    models.append(catalogModel); settle()
    catalogModel.addCatalogFolder("/fixture/personal")
    let entry = CatalogEntry(id: "thr_discovered_1", title: "Discovered work", folder: "/fixture/personal", updatedAt: Date())
    catalogModel.prepare()
    catalogModel.beginSearch("discovered")
    catalogModel.acceptCatalog(entries: [entry], truncated: false)
    check(catalogModel.results.isEmpty && catalogModel.updateReady, "catalog refresh stages results during typed search")
    catalogModel.query = "discovered"
    check(catalogModel.results.isEmpty, "typed search uses frozen catalog during refresh")
    catalogModel.applyCatalogUpdate()
    check(catalogModel.results.count == 1 && !catalogModel.updateReady, "explicit refresh installs discovered results")
    check(catalogModel.mode == .search && catalogModel.query == "discovered", "applying new chats keeps the typed search")
    let selected = catalogModel.selectedID
    catalogModel.acceptCatalog(entries: [entry, CatalogEntry(id: "thr_discovered_2", title: "New work", folder: "/fixture/personal", updatedAt: Date())], truncated: false)
    check(catalogModel.selectedID == selected && catalogModel.results.count == 1, "new catalog does not move selection")
    settle(); catalogModel.endPresentation(); catalogModel.prepare()
    check(catalogModel.results.count == 2, "next invocation adopts new catalog")
    catalogModel.acceptedDispatch(entry.destination.id)
    check(catalogModel.state.destinations.first?.threadID == entry.id && catalogModel.state.destinations.first?.lastOpenedAt != nil, "discovered selection becomes remembered destination")
    catalogModel.acceptCatalog(entries: [CatalogEntry(id: entry.id, title: "Renamed in Codex", folder: "/fixture/personal", updatedAt: Date()),
        CatalogEntry(id: "thr_discovered_2", title: "New work", folder: "/fixture/personal", updatedAt: Date())], truncated: false)
    check(catalogModel.state.destinations.first?.title == "Renamed in Codex", "a chat saved by opening it follows Codex's renames")
    catalogModel.removeCatalogFolder("/fixture/personal")
    check(catalogModel.results.count == 1, "removing discovery scope preserves saved destination")
    let reloaded = AppModel(repository: catalogModel.repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    models.append(reloaded)
    check(reloaded.results.count == 1, "catalog and saved state survive reload")
    // A failed open is shown for that opening only; a lasting problem stays visible.
    let errorModel = AppModel(repository: StateRepository(url: temporary.appendingPathComponent("error-state.json")),
                              catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    models.append(errorModel); settle()
    errorModel.reportTransientError("Couldn’t open this conversation.")
    errorModel.prepare()
    check(errorModel.error == nil, "a failed open's error clears at the next opening")
    errorModel.endPresentation(); errorModel.error = "Couldn't register the shortcut"
    errorModel.prepare()
    check(errorModel.error != nil, "a lasting problem stays visible across openings")
    errorModel.endPresentation(); errorModel.error = nil
    // A shortcut still taken by another app does not block saving the other settings.
    errorModel.changeShortcut = { _ in throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shortcut in use"]) }
    errorModel.showSettings(); errorModel.rememberDraft = false; errorModel.saveSettings()
    check(!errorModel.state.rememberRecents && errorModel.shortcutStatus == "Shortcut in use",
          "an unchanged shortcut that is still taken does not block saving other settings")
    errorModel.showSettings(); errorModel.shortcutDraft = Shortcut(key: "K"); errorModel.saveSettings()
    check(errorModel.state.shortcut == Shortcut(), "a new shortcut that cannot be registered is not saved")
    // Recognition details freeze with the visible choices until the next invocation.
    let previewDirectory = temporary.appendingPathComponent("preview")
    let previewRepository = StateRepository(url: previewDirectory.appendingPathComponent("destinations.json"))
    let previewItem = Destination(title: "Recognizable conversation", threadID: "thr_preview_frozen")
    var previewState = SavedState(); previewState.destinations = [previewItem]
    try? previewRepository.save(previewState)
    let previewDate = Date()
    var previewCatalog = CatalogCache(); previewCatalog.folders = ["/fixture/Spleen"]
    previewCatalog.refreshedAt = previewDate
    previewCatalog.entries = [CatalogEntry(id: previewItem.threadID, title: previewItem.title, folder: "/fixture/Spleen", updatedAt: previewDate)]
    try? previewCatalog.save(to: previewDirectory.appendingPathComponent("catalog.json"))
    var previewNotes = InsightCache()
    previewNotes.entries = [ThreadInsight(id: previewItem.threadID, folder: "/fixture/Spleen", updatedAt: previewDate, topic: "The exchange I recognize")]
    try? previewNotes.save(to: previewDirectory.appendingPathComponent("relevance.json"))
    let previewModel = AppModel(repository: previewRepository, catalogFetcher: { _ in throw CatalogError.unavailable }, insightFetcher: { _, _ in [] })
    models.append(previewModel); settle(); previewModel.prepare()
    check(previewModel.preview(previewItem).excerpt == "The exchange I recognize", "selected preview reads the prepared excerpt")
    previewModel.acceptCatalog(entries: [CatalogEntry(id: previewItem.threadID, title: previewItem.title,
        folder: "/fixture/Spleen", updatedAt: previewDate.addingTimeInterval(1))], truncated: false)
    check(previewModel.preview(previewItem).excerpt == "The exchange I recognize", "background catalog changes preserve the visible preview")
    previewModel.endPresentation(); previewModel.prepare()
    check(previewModel.preview(previewItem).excerpt == nil, "next invocation drops an excerpt after its source changes")
    previewModel.endPresentation()

    // Existing excerpt caches are upgraded in place through the same bounded background fetch.
    let timingDirectory = temporary.appendingPathComponent("timing-backfill")
    let timingRepository = StateRepository(url: timingDirectory.appendingPathComponent("destinations.json"))
    try? timingRepository.save(previewState)
    try? previewCatalog.save(to: timingDirectory.appendingPathComponent("catalog.json"))
    try? previewNotes.save(to: timingDirectory.appendingPathComponent("relevance.json"))
    let finishedAt = previewDate.addingTimeInterval(-120)
    let timingModel = AppModel(repository: timingRepository,
        catalogFetcher: { _ in (previewCatalog.entries, false) }, insightFetcher: { entries, _ in
            entries.map { ThreadInsight(id: $0.id, folder: $0.folder, updatedAt: $0.updatedAt,
                topic: "Updated excerpt", timing: TurnTiming(lastCompletedAt: finishedAt, checkedAt: previewDate)) }
        })
    models.append(timingModel); settle()
    let timingDeadline = Date().addingTimeInterval(3)
    while timingModel.preview(previewItem).timing == nil && Date() < timingDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    check(timingModel.preview(previewItem).timing?.lastCompletedAt == finishedAt,
          "legacy excerpt receives startup timing backfill even with a fresh catalog cache")
    check(timingModel.timingLabel(previewItem) == "Last reply 2m ago", "card completion time comes from the source turn")
    timingModel.prepare()
    timingModel.acceptCatalog(entries: [CatalogEntry(id: previewItem.threadID, title: previewItem.title,
        folder: "/fixture/Spleen", updatedAt: previewDate.addingTimeInterval(1))], truncated: false)
    check(timingModel.preview(previewItem).timing?.lastCompletedAt == finishedAt,
          "background source changes preserve the visible completion timestamp")
    timingModel.endPresentation()

    // First startup snapshot can populate an empty, untouched panel without a manual refresh.
    let coldRepository = StateRepository(url: temporary.appendingPathComponent("cold/state.json"))
    var coldState = SavedState(); coldState.destinations = [Destination(title: "Cached startup", threadID: "thr_cached_startup")]
    try? coldRepository.save(coldState)
    let cold = AppModel(repository: coldRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    models.append(cold); cold.prepare()
    check(cold.results.first?.title == "Cached startup" && !cold.updateReady, "cold startup adopts first cached index into untouched empty panel")
    // A later catalog build must preserve an explicit edit's pending adoption intent.
    catalogModel.edit(catalogModel.state.destinations[0]); catalogModel.editorTitle = "Edited while indexing"; catalogModel.saveEditor()
    catalogModel.acceptCatalog(entries: [], truncated: false)
    check(catalogModel.results.first?.title == "Edited while indexing", "catalog generation cannot supersede explicit edit adoption")
    catalogModel.applyCatalogUpdate()
    catalogModel.acceptCatalog(entries: [], truncated: false)
    check(!catalogModel.updateReady, "unchanged catalog does not advertise an update")
    // Provider completion after a scope removal cannot reintroduce old topic notes.
    let gate = DispatchSemaphore(value: 0)
    let stale = AppModel(repository: StateRepository(url: temporary.appendingPathComponent("stale/state.json")),
        catalogFetcher: { _ in throw CatalogError.unavailable }, insightFetcher: { entries, _ in
            _ = gate.wait(timeout: .now() + 2)
            return entries.map { ThreadInsight(id: $0.id, folder: $0.folder, updatedAt: $0.updatedAt, topic: "Retired SQLite evidence") }
        })
    models.append(stale); settle(); stale.addCatalogFolder("/fixture/personal")
    stale.acceptCatalog(entries: [entry], truncated: false)
    stale.removeCatalogFolder("/fixture/personal"); gate.signal()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    stale.prepare(); stale.query = "SQLite"
    check(stale.results.isEmpty && stale.catalog.entries.isEmpty, "late enrichment cannot restore removed folder evidence")
    var durations: [Double] = []
    for _ in 0..<100 { model.endPresentation(); model.prepare(); durations.append(model.prepareMilliseconds) }
    durations.sort()
    print(String(format: "Warm model preparation, 100 samples / 2 saved entries: median %.3f ms, p95 %.3f ms, max %.3f ms. Not screen-render or physical-hotkey latency.", durations[50], durations[94], durations[99]))
    let largeRepository = StateRepository(url: temporary.appendingPathComponent("large/state.json"))
    var largeState = SavedState()
    largeState.destinations = (0..<1000).map { Destination(title: "Synthetic chat \($0)", threadID: "thr_benchmark_\($0)") }
    try? largeRepository.save(largeState)
    let large = AppModel(repository: largeRepository, catalogFetcher: { _ in throw CatalogError.unavailable }, insightFetcher: { _, _ in [] })
    models.append(large); settle()
    var opening: [Double] = [], searching: [Double] = []
    for _ in 0..<100 {
        large.endPresentation(); large.prepare(); opening.append(large.prepareMilliseconds)
        let start = ProcessInfo.processInfo.systemUptime
        large.query = "Synthetic chat 99"
        searching.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    opening.sort(); searching.sort()
    check(large.results.prefix(11).allSatisfy { $0.title.hasPrefix("Synthetic chat 99") }, "1000-row model preserves title match precedence")
    check(opening[94] < 5 && searching[94] < 20, "1000-row cached model preparation and search stay within local latency budgets")
    print(String(format: "Warm AppModel / 1000 synthetic entries / 100 samples: opening p95 %.3f ms, search p95 %.3f ms. Not screen-render or physical-hotkey latency.", opening[94], searching[94]))
    let activity = runActivityIntegrationTests()
    count += activity.passed + activity.failures.count
    failures += activity.failures
    let attention = runAttentionTests()
    count += attention.passed + attention.failures.count
    failures += attention.failures
    let background = runBackgroundWorkTests()
    count += background.passed + background.failures.count
    failures += background.failures
    let desktop = runDesktopTests()
    count += desktop.passed + desktop.failures.count
    failures += desktop.failures
    let handoff = runSearchHandoffChecks()
    count += handoff.passed + handoff.failures.count
    failures += handoff.failures
    let keyboard = runKeyboardReadinessTests()
    count += keyboard.passed + keyboard.failures.count
    failures += keyboard.failures
    let recents = runRecentSessionTests()
    count += recents.passed + recents.failures.count
    failures += recents.failures
    let dot = runDotTests()
    count += dot.passed + dot.failures.count
    failures += dot.failures
    let readiness = runReadinessTests()
    count += readiness.passed + readiness.failures.count
    failures += readiness.failures
    let returns = runReturnReadinessTests()
    count += returns.passed + returns.failures.count
    failures += returns.failures
    let monitor = runContextMonitorTests()
    count += monitor.passed + monitor.failures.count
    failures += monitor.failures
    print("App self-test: \(count - failures.count)/\(count) checks passed. Dispatch and restoration callbacks were injected; no external hotkey or Codex arrival was tested.")
    return failures.isEmpty
}
