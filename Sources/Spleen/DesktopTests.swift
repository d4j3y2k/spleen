import AppKit
import SpleenCore

// These integration checks address only Spleen's own windows. External dispatch,
// focus restoration, catalog providers, and prediction transport are injected.
func runDesktopTests() -> (passed: Int, failures: [String]) {
    var failures: [String] = []
    var count = 0
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-desktop-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    @discardableResult func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        return predicate()
    }
    func makeModel(_ name: String, items: [Destination], transport: DecisionsTransport? = nil) throws -> AppModel {
        let repository = StateRepository(url: directory.appendingPathComponent(name).appendingPathComponent("state.json"))
        var state = SavedState()
        state.version = items.contains { $0.provider == .claude } ? 2 : 1
        state.destinations = items
        try repository.save(state)
        let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) },
                             insightFetcher: { _, _ in [] }, rankingTransport: transport)
        check(wait { !model.indexing }, "\(name): cached snapshot settles")
        return model
    }
    func key(_ controller: PanelController, _ code: UInt16, _ text: String,
             modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.panel.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeated, keyCode: code)!
    }
    do {
        let items = (0..<7).map { Destination(title: "Alpha conversation \($0)", threadID: "thr_desktop_fixture_\($0)") }
        let model = try makeModel("keyboard", items: items)
        let controller = PanelController(model: model)
        defer { controller.dismiss(.cancel) }
        var currentPID: Int32 = 101
        var restored: [Int32] = []
        var urls: [URL] = []
        controller.currentPID = { currentPID }
        controller.restorePID = { restored.append($0) }
        controller.dispatchURL = { urls.append($0); return true }
        controller.present()
        let initial = model.compassItems
        check(model.mode == .compass && initial.count == 5 && model.selectedID == initial.first?.id,
              "invocation selects prepared center and limits compass to five")
        check(controller.panel.frame.size == CompassLayout.size, "compass reserves space for the selected conversation preview")
        controller.handleKeyDown(key(controller, 124, "\u{F703}"))
        check(model.selectedID == initial[2].id, "right arrow selects right slot")
        controller.handleKeyDown(key(controller, 124, "\u{F703}"))
        check(model.selectedID == initial[2].id, "outward arrow retains selected arm")
        controller.handleKeyDown(key(controller, 123, "\u{F702}"))
        check(model.selectedID == initial[0].id && model.compassItems == initial,
              "opposite arrow returns center without reordering")
        check(CompassSelection.next(currentID: initial[0].id, items: Array(initial.prefix(2)), direction: .left) == initial[0].id,
              "missing directional slot retains current choice")
        controller.handleKeyDown(key(controller, 49, " ", modifiers: [.control, .option]))
        controller.handleKeyDown(key(controller, 49, " ", repeated: true))
        controller.handleKeyDown(key(controller, 36, "\r", repeated: true))
        check(urls.isEmpty && controller.session.isPresented, "held invocation modifiers and repeated confirmation cannot dispatch")
        for (code, text) in [(UInt16(49), " "), (UInt16(36), "\r"), (UInt16(76), "\r")] {
            if !controller.session.isPresented { controller.present() }
            let selected = model.compassItems[1]
            model.selectedID = selected.id
            let before = urls.count
            controller.handleKeyDown(key(controller, code, text))
            check(urls.count == before + 1 && urls.last == (try? selected.navigationURL) && !controller.session.isPresented,
                  "confirmation key \(code) dispatches selected canonical URL once")
            check(wait { !model.indexing }, "dispatch snapshot settles for key \(code)")
        }
        controller.present()
        model.selectedID = model.compassItems[2].id
        let failedOrder = model.compassItems, failedSelection = model.selectedID
        controller.dispatchURL = { _ in false }
        currentPID = ProcessInfo.processInfo.processIdentifier
        model.openSelected()
        check(controller.session.isPresented && model.compassItems == failedOrder && model.selectedID == failedSelection && controller.session.priorPID == 101,
              "failed dispatch preserves choices, selection, and original focus target")
        restored = []
        controller.handleKeyDown(key(controller, 53, "\u{1B}"))
        check(restored == [101] && !controller.session.isPresented, "Escape after failed dispatch restores original app")

        currentPID = 101
        controller.present()
        model.edit()
        check(controller.handleKeyDown(key(controller, 49, " ")) != nil && model.mode == .editor,
              "editor retains ordinary spaces")
        controller.dismiss(.cancel)
        controller.present()
        controller.handleKeyDown(key(controller, 0, "a"))
        controller.handleKeyDown(key(controller, 37, "l"))
        check(wait { model.query == "al" }, "first and rapid next characters replay into native cached search")
        check(model.mode == .search && !model.results.isEmpty && model.results.allSatisfy { $0.title.hasPrefix("Alpha") },
              "typing searches frozen local conversations")
        check(controller.panel.frame.size == SpleenStyle.managementSize, "search resizes management panel")
        check(controller.handleKeyDown(key(controller, 49, " ")) != nil && controller.session.isPresented,
              "search retains ordinary spaces")
        if let editor = controller.panel.firstResponder as? NSTextView {
            editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            check(editor.hasMarkedText() && controller.handleKeyDown(key(controller, 36, "\r")) != nil,
                  "input-method marked text retains Enter for composition")
            check(controller.handleKeyDown(key(controller, 53, "\u{1B}")) != nil && controller.session.isPresented,
                  "input-method marked text retains Escape for composition")
            editor.unmarkText()
        } else { check(false, "native search owns a text input responder") }
        model.showSettings()
        controller.dismiss(.cancel)
        controller.present()
        check(model.mode == .compass && model.query.isEmpty && model.selectedID == model.compassItems.first?.id,
              "new invocation after management restores prepared compass")
        controller.dismiss(.cancel)

        let returnPin = Destination(title: "Pinned reference", threadID: "thr_return_pin", pinned: true)
        let returnA = Destination(title: "Conversation A", threadID: "thr_return_a", lastOpenedAt: Date().addingTimeInterval(-60))
        let returnB = Destination(title: "Conversation B", threadID: "thr_return_b", lastOpenedAt: Date().addingTimeInterval(-30))
        let returning = try makeModel("returning", items: [returnPin, returnA, returnB])
        let returnController = PanelController(model: returning)
        returnController.currentPID = { 101 }; returnController.restorePID = { _ in }
        var returned: [URL] = []
        returnController.dispatchURL = { returned.append($0); return true }
        returnController.present()
        check(returning.compassItems.map(\.id) == [returnA.id, returnPin.id, returnB.id],
              "center suggests previous conversation while the pin stays on an arm")
        returning.openSelected()
        check(wait { !returning.indexing }, "return to A prepares the next suggestion")
        returnController.present()
        check(returning.compassItems.first?.id == returnB.id && returning.selectedID == returnB.id,
              "reopening after dispatch selects B instead of the pin or A")
        returning.openSelected()
        check(wait { !returning.indexing }, "return to B prepares the next suggestion")
        returnController.present()
        let expectedReturnURLs = try [returnA.navigationURL, returnB.navigationURL]
        check(returning.compassItems.first?.id == returnA.id && returned == expectedReturnURLs,
              "successive center confirmations switch A to B and back")
        returnController.dismiss(.cancel)

        let sharedID = "01234567-89ab-cdef-0123-456789abcdef"
        let mixedItems = [Destination(title: "Codex counterpart", threadID: sharedID),
                          Destination(title: "Claude counterpart", threadID: sharedID, provider: .claude)]
        let mixed = try makeModel("mixed", items: mixedItems)
        mixed.prepare()
        var mixedURLs: [URL] = []
        mixed.openDestination = { if let url = try? $0.navigationURL { mixedURLs.append(url) } }
        for item in mixedItems { mixed.selectedID = item.id; mixed.openSelected() }
        check(mixed.results.count == 2 && Set(mixed.results.map(\.conversationKey)).count == 2 && Set(mixedURLs).count == 2,
              "equal provider UUIDs remain distinct saved and navigable conversations")
        check(mixedURLs.map(\.absoluteString) == ["codex://threads/\(sharedID)", "claude://claude.ai/chat/\(sharedID)"],
              "mixed provider dispatch uses each canonical app route")
        mixed.endPresentation()

        let frozenClaudeOthers = (0..<8).map { Destination(title: "Other conversation \($0)", threadID: "thr_claude_other_\($0)") }
        let frozenClaude = try makeModel("frozen-claude", items: frozenClaudeOthers)
        let frozenClaudeStore = ContextRepository(url: frozenClaude.repository.url.deletingLastPathComponent().appendingPathComponent("context.json"))
        let frozenClaudeKey = ConversationKey(provider: .claude, id: "desktop-code:local_" + sharedID)
        try frozenClaudeStore.record(ContextEvent(key: frozenClaudeKey, topic: "Frozen Code visit", kind: .selectedConversation,
            source: "claude-desktop-accessibility", evidence: .observedSelection))
        check(wait { frozenClaude.context.currentHint()?.key == frozenClaudeKey && !frozenClaude.indexing },
              "frozen Claude fixture prepares an observed destination")
        let frozenClaudeController = PanelController(model: frozenClaude)
        frozenClaudeController.currentPID = { 101 }; frozenClaudeController.restorePID = { _ in }
        var frozenClaudeURLs: [URL] = []
        frozenClaudeController.dispatchURL = { frozenClaudeURLs.append($0); return true }
        frozenClaudeController.present()
        let frozenClaudeChoices = frozenClaude.compassItems
        let observedChoice = frozenClaudeChoices.first { $0.conversationKey == frozenClaudeKey }
        check(observedChoice != nil && frozenClaudeChoices.first?.conversationKey != frozenClaudeKey,
              "newly observed Claude session stays nearby in a crowded picker while another chat takes center")
        frozenClaude.selectedID = observedChoice?.id
        try frozenClaudeStore.setRecentsEnabled(true, clear: true)
        check(wait { frozenClaude.context.events.isEmpty && !frozenClaude.indexing && frozenClaude.updateReady },
              "background context removal prepares a replacement without the frozen Code visit")
        check(frozenClaude.compassItems == frozenClaudeChoices && frozenClaudeChoices.count == 5,
              "removed prepared Code candidate remains fixed in its active invocation")
        frozenClaude.openSelected()
        check(frozenClaudeURLs.map(\.absoluteString) == ["claude://claude.ai/epitaxy/local_" + sharedID] &&
              !frozenClaudeController.session.isPresented && frozenClaude.state.destinations == frozenClaudeOthers &&
              frozenClaude.context.events.contains { $0.key == frozenClaudeKey && $0.kind == .spleenDispatch && $0.evidence == .spleenInteraction },
              "controller dispatch records the frozen Code key after ending presentation even when prepared candidates removed it")
        check(wait { !frozenClaude.indexing }, "frozen Claude dispatch preparation settles")

        let contextModel = try makeModel("context", items: items)
        contextModel.prepare()
        let visible = contextModel.compassItems, selection = contextModel.selectedID
        let contextRepository = ContextRepository(url: contextModel.repository.url.deletingLastPathComponent().appendingPathComponent("context.json"))
        let lifecycle = ContextEvent(key: items[5].conversationKey, kind: .turnCompleted, source: "fixture-hook", evidence: .lifecycle)
        try contextRepository.record(lifecycle)
        check(wait { contextModel.context.events.contains(lifecycle) && !contextModel.indexing }, "external lifecycle context is adopted off invocation path")
        check(contextModel.context.currentHint() == nil && contextModel.context.latestObservedSelection() == nil,
              "lifecycle context does not claim selection or foreground interaction")
        let observed = ContextEvent(key: items[6].conversationKey, kind: .selectedConversation, source: "fixture-observer", evidence: .observedSelection)
        try contextRepository.record(observed)
        check(wait { contextModel.context.latestObservedSelection()?.key == items[6].conversationKey && !contextModel.indexing },
              "external observed selection updates local context")
        check(contextModel.compassItems == visible && contextModel.selectedID == selection,
              "context completion preserves visible compass and selection")
        contextModel.endPresentation()

        let pausedRepository = StateRepository(url: directory.appendingPathComponent("paused/state.json"))
        var pausedState = SavedState(); pausedState.rememberRecents = false
        try pausedRepository.save(pausedState)
        let pausedContext = ContextRepository(url: pausedRepository.url.deletingLastPathComponent().appendingPathComponent("context.json"))
        try pausedContext.record(lifecycle)
        let paused = AppModel(repository: pausedRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { (try? pausedContext.load().recentsEnabled) == false && !paused.indexing },
              "legacy disabled recents also pause the persistent hook store")
        try pausedContext.record(lifecycle)
        let pausedReloaded = try pausedContext.load()
        check(pausedReloaded.events.isEmpty, "paused hook store retains no subsequent lifecycle events")

        let transport = DesktopPredictionFixture()
        let predicted = try makeModel("prediction", items: Array(items.prefix(3)), transport: transport)
        predicted.prepare()
        let beforePrediction = predicted.compassItems
        check(transport.calls == 1, "prediction begins once off invocation path")
        try transport.complete(choice: 2, candidateCount: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(predicted.compassItems == beforePrediction && predicted.selectedID == beforePrediction.first?.id,
              "ready prediction cannot move an open compass")
        predicted.endPresentation(); predicted.prepare()
        check(predicted.compassItems.first?.id == items[2].id, "ready prediction is adopted on next invocation")
        for _ in 0..<100 {
            predicted.beginSearch("Alpha")
            predicted.endPresentation()
            predicted.prepare()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        check(transport.calls == 1, "100 cached opens and searches make no additional prediction calls")
        predicted.endPresentation()
    } catch { check(false, "desktop integration fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}

private final class DesktopPredictionFixture: DecisionsTransport {
    private(set) var calls = 0
    private var completion: ((Result<Data, Error>) -> Void)?
    func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
        calls += 1
        guard calls <= 4 else { completion(.failure(RankingError.budgetExhausted)); return {} }
        self.completion = completion
        return {}
    }
    func complete(choice: Int, candidateCount: Int) throws {
        let probabilities: [[String: Any]] = (0..<candidateCount).map {
            ["value": "c\($0)", "probability": $0 == choice ? 0.9 : 0.0]
        } + [["value": "none", "probability": 0.1]]
        let data = try JSONSerialization.data(withJSONObject: ["answers": [[
            "type": "choice", "name": "next_chat", "choice": "c\(choice)",
            "confidence": 0.9, "probabilities": probabilities
        ]]])
        completion?(.success(data))
        completion = nil
    }
}
