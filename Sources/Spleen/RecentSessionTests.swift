import AppKit
import SpleenCore

func runRecentSessionTests() -> (passed: Int, failures: [String]) {
    var count = 0, failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return predicate()
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-recents-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let repository = StateRepository(url: directory.appendingPathComponent("state.json"))
        let instant = Date()
        var state = SavedState()
        state.destinations = (0..<12).map { index in
            var item = Destination(title: "Session \(index)", threadID: "thr_recent_\(index)")
            item.lastOpenedAt = instant.addingTimeInterval(-Double(index + 1) * 60)
            return item
        }
        try repository.save(state)
        let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !model.indexing }, "recent sessions fixture is ready")
        let controller = PanelController(model: model)
        controller.currentPID = { nil }; controller.restorePID = { _ in }
        var dispatched: [URL] = []
        controller.dispatchURL = { dispatched.append($0); return true }
        defer { controller.dismiss(.cancel) }
        func press(_ code: UInt16, repeated: Bool = false, characters: String = "") {
            controller.handleKeyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeated, keyCode: code)!)
        }
        controller.present(orderFront: false)
        check(model.recentSessions.map(\.id) == state.destinations.map(\.id), "recents preserve chronological order independently of compass ranking")
        let compass = model.compassItems
        let refreshes = model.resultRefreshCount, builds = model.snapshotBuildCount
        press(124)
        check(!model.browsingRecents && model.selectedID == compass[2].id, "first Right selects the right compass arm")
        press(124, repeated: true)
        check(!model.browsingRecents, "held first Right does not accidentally enter recents")
        press(124)
        check(model.browsingRecents && model.selectedID == state.destinations[0].id, "second Right enters the newest recent session")
        check(model.selectedCompassPreview?.id == state.destinations[0].id, "preview follows recent selection")
        press(126)
        check(model.selectedID == state.destinations[0].id, "recent Up clamps at top")
        press(125); press(125, repeated: true)
        check(model.selectedID == state.destinations[2].id, "recent Down supports deliberate key repeat")
        press(124)
        check(model.selectedID == state.destinations[2].id && model.browsingRecents, "Right inside recents keeps selection")
        press(123)
        check(!model.browsingRecents && model.selectedID == compass[2].id, "Left returns to the right compass arm")
        press(123)
        check(model.selectedID == compass[0].id, "another Left returns to center")
        check(model.compassItems == compass && model.resultRefreshCount == refreshes && model.snapshotBuildCount == builds,
              "recent navigation neither moves compass slots nor rebuilds the index")
        press(124); press(124)
        for _ in 0..<20 { press(125) }
        let last = state.destinations.last!
        check(model.selectedID == last.id && model.selectedCompassPreview?.id == last.id, "navigation reaches and previews sessions outside the compass, clamping at bottom")
        let frozen = model.recentSessions
        model.receiveLiveState(LiveSessionState(key: last.conversationKey, source: "fixture", observedAt: Date(), sequence: 1, activity: .working, isUnread: nil))
        check(wait { !model.indexing }, "recent browsing background rebuild completes")
        check(model.recentSessions == frozen && model.selectedID == last.id && model.browsingRecents, "background updates preserve recent order and selection")
        controller.dispatchURL = { _ in false }
        press(36)
        check(controller.session.isPresented && model.browsingRecents && model.selectedID == last.id && model.recentSessions == frozen,
              "rejected recent dispatch restores the same list and selection")
        controller.dispatchURL = { dispatched.append($0); return true }
        press(49, repeated: true)
        check(dispatched.isEmpty, "repeated Space never dispatches a recent session")
        press(49)
        check(dispatched.last == (try? last.navigationURL) && !controller.session.isPresented, "Space dispatches the exact recent destination outside compass")
        controller.present(orderFront: false)
        check(model.recentSessions.first?.id == last.id && !model.browsingRecents,
              "immediate reopen promotes the dispatched recent session and resets compass focus")
        press(124); press(124)
        press(0, characters: "s")
        check(wait { model.mode == .search && model.query == "s" }, "typing from recents enters native search without losing the first key")
        press(53)
        check(!controller.session.isPresented, "Escape closes search after recent browsing")
        controller.present(orderFront: false)
        press(124); press(124); press(53)
        check(!controller.session.isPresented, "Escape closes directly from the recent list")
        model.clearRecents()
        check(wait { !model.indexing }, "clear history rebuild finishes")
        controller.present(orderFront: false)
        check(model.recentSessions.isEmpty, "clearing history removes recent rows")
        press(124); press(124)
        check(!model.browsingRecents && model.selectedID == model.compassItems[2].id, "empty recents do not trap compass navigation")
        controller.dismiss(.cancel)

        let sparseRepository = StateRepository(url: directory.appendingPathComponent("sparse/state.json"))
        state.destinations = Array(state.destinations.prefix(1))
        try sparseRepository.save(state)
        let sparse = AppModel(repository: sparseRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !sparse.indexing }, "sparse recent fixture is ready")
        sparse.prepare(); sparse.navigateCompass(.right)
        check(!sparse.browsingRecents, "sparse compass first Right stays on its sole choice")
        sparse.navigateCompass(.right)
        check(sparse.browsingRecents && sparse.selectedID == state.destinations[0].id, "sparse compass second Right enters recents even with the same destination")
        sparse.navigateCompass(.left)
        check(!sparse.browsingRecents && sparse.selectedID == state.destinations[0].id, "sparse Left restores compass selection")
        sparse.endPresentation()

        let deterministicDirectory = directory.appendingPathComponent("deterministic")
        let deterministicRepository = StateRepository(url: deterministicDirectory.appendingPathComponent("state.json"))
        var deterministicState = SavedState()
        deterministicState.version = 3
        deterministicState.destinations = (0..<6).map { index in
            Destination(title: "Actually selected \(index)", threadID: "thr_navigation_\(index)", lastOpenedAt: instant.addingTimeInterval(-Double(index + 1) * 7200))
        }
        deterministicState.destinations.append(Destination(title: "Old irrelevant task", threadID: "thr_old_unused"))
        let claudeRecent = Destination(title: "Claude recent reply", threadID: "desktop-code:local_11111111-1111-4111-8111-111111111111",
            lastOpenedAt: instant.addingTimeInterval(-14 * 3600), provider: .claude)
        deterministicState.destinations.append(claudeRecent)
        try deterministicRepository.save(deterministicState)
        try Data("{\"navigationFirstCompass\":true}".utf8).write(to: deterministicDirectory.appendingPathComponent("context-settings.json"))
        var timingCatalog = CatalogCache()
        timingCatalog.folders = ["/fixture"]
        timingCatalog.refreshedAt = instant
        timingCatalog.entries = [0, 5].map { index in
            let item = deterministicState.destinations[index]
            return CatalogEntry(id: item.threadID, title: item.title, folder: "/fixture", updatedAt: instant)
        }
        try timingCatalog.save(to: deterministicDirectory.appendingPathComponent("catalog.json"))
        var timingNotes = InsightCache()
        timingNotes.entries = timingCatalog.entries.map { entry in
            ThreadInsight(id: entry.id, folder: entry.folder, updatedAt: entry.updatedAt, topic: "Cached reply",
                timing: TurnTiming(lastCompletedAt: instant.addingTimeInterval(-120), checkedAt: instant))
        }
        try timingNotes.save(to: deterministicDirectory.appendingPathComponent("relevance.json"))
        let deterministic = AppModel(repository: deterministicRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] }, now: { instant })
        check(wait { !deterministic.indexing }, "deterministic compass fixture prepared")
        deterministic.receiveClaudeReply(ClaudeReplyTime(label: "12 minutes ago", observedAt: instant)!, for: claudeRecent.conversationKey)
        deterministic.prepare()
        check(deterministic.compassItems.map(\.threadID) == deterministicState.destinations.prefix(5).map(\.threadID), "main compass uses actual navigation even after30minutes")
        check(deterministic.timingLabel(deterministic.compassItems[0]) == "Last reply 2m ago\nLast selected 2h ago",
              "navigation cards show reply completion alongside selection time")
        check(deterministic.timingHelp(deterministic.compassItems[0]).contains("Last completed turn:") &&
              deterministic.timingHelp(deterministic.compassItems[0]).contains("Last selected through Spleen:"),
              "dual timestamps retain both exact times and provenance in the tooltip")
        check(deterministic.timingLabel(deterministic.compassItems[1]) == "Last selected 4h ago",
              "missing reply time keeps selection without inventing a reply")
        check(deterministic.recentSessions.prefix(6).map(\.id) == deterministicState.destinations.prefix(6).map(\.id),
              "newer background replies do not reorder the recent list")
        let outsideCompass = deterministic.recentSessions[5].destination
        check(deterministic.timingLabel(outsideCompass) == "Last reply 2m ago\nLast selected 12h ago",
              "recent rows outside the compass show reply and selection times")
        deterministic.selectRecent(outsideCompass.id)
        check(deterministic.selectedCompassPreview?.id == outsideCompass.id &&
              deterministic.timingLabel(outsideCompass, separator: " · ") == "Last reply 2m ago · Last selected 12h ago",
              "selected preview and search expose both timestamps in a compact line")
        check(deterministic.timingLabel(claudeRecent) == "Last reply ≈12m ago\nLast selected 14h ago",
              "Claude approximate reply remains visible beside selection in navigation mode")
        deterministic.beginSearch("Old irrelevant")
        check(deterministic.results.map(\.threadID) == ["thr_old_unused"], "catalog-only sessions remain searchable")
        deterministic.endPresentation()
        deterministic.clearRecents()
        check(wait { !deterministic.indexing }, "deterministic clear prepared")
        deterministic.prepare()
        check(deterministic.compassItems.isEmpty, "empty navigation never falls back to unrelated catalog")
        deterministic.endPresentation()

        let creationDirectory = directory.appendingPathComponent("creation")
        let creationRepository = StateRepository(url: creationDirectory.appendingPathComponent("state.json"))
        let creationTime = Date()
        var creationState = SavedState()
        creationState.destinations = [Destination(title: "Earlier selection", threadID: "thr_creation_selected", lastOpenedAt: creationTime.addingTimeInterval(-120))]
        try creationRepository.save(creationState)
        try Data("{\"navigationFirstCompass\":true}".utf8).write(to: creationDirectory.appendingPathComponent("context-settings.json"))
        var creationCatalog = CatalogCache(); creationCatalog.folders = ["/fixture"]; creationCatalog.refreshedAt = creationTime
        try creationCatalog.save(to: creationDirectory.appendingPathComponent("catalog.json"))
        let created = CatalogEntry(id: "thr_creation_new", title: "Created directly in Codex", folder: "/fixture", updatedAt: creationTime, createdAt: creationTime)
        let journal = ActivityHookRepository(url: creationDirectory.appendingPathComponent("activity-hooks.json"))
        _ = try journal.setEnabled(true)
        let creationModel = AppModel(repository: creationRepository, catalogFetcher: { _ in ([created], false) }, insightFetcher: { _, _ in [] })
        check(wait { !creationModel.indexing }, "creation fixture prepared with a fresh catalog")
        creationModel.prepare()
        let frozenCreationList = creationModel.recentSessions
        let receivedAt = Date()
        _ = try journal.record(ActivityHookEvent(key: created.destination.conversationKey, project: "/fixture",
            kind: .sessionStarted, receivedAt: receivedAt), now: receivedAt)
        check(wait { creationModel.catalog.entries.contains(created) && !creationModel.indexing },
              "SessionStart discovers a new chat before any completion despite fresh catalog TTL")
        check(creationModel.recentSessions == frozenCreationList, "creation discovery preserves an open recent list")
        creationModel.endPresentation(); creationModel.prepare()
        check(creationModel.recentSessions.first?.destination.threadID == created.id,
              "directly created Codex chat appears first on reopening")
        check(creationModel.timingLabel(created.destination) == "Created just now" &&
              creationModel.preview(created.destination).lastVisitedAt == nil,
              "creation is labelled accurately without inventing a visit")
        creationModel.endPresentation(); creationModel.clearRecents()
        check(wait { !creationModel.indexing }, "creation clear prepared")
        creationModel.prepare()
        check(creationModel.recentSessions.isEmpty, "clearing history also suppresses catalog creation timestamps")
        creationModel.endPresentation()
    } catch { check(false, "recent sessions fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}
