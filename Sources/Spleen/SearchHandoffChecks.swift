import AppKit
import Combine
import SpleenCore

func runSearchHandoffChecks() -> (passed: Int, failures: [String]) {
    var count = 0, failures: [String] = []
    func check(_ condition: Bool, _ label: String) {
        count += 1
        if !condition { failures.append(label); print("FAIL: \(label)") }
    }
    func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return predicate()
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-handoff-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
        let repository = StateRepository(url: temporary.appendingPathComponent("cold-state.json"))
        var state = SavedState()
        state.destinations = [Destination(title: "Keypad piano", threadID: "thr_handoff_cold")]
        try repository.save(state)
        let coldModel = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        let coldController = PanelController(model: coldModel)
        coldController.currentPID = { nil }; coldController.restorePID = { _ in }
        coldController.receiveSearch(SearchHandoff(query: "keypad"), orderFront: false)
        check(wait { coldModel.results.contains(where: { $0.threadID == "thr_handoff_cold" }) }, "cold incoming search adopts the first prepared index")
        check(coldModel.query == "keypad" && !coldModel.updateReady, "initial index adoption preserves the transferred query")
        coldController.dismiss(.cancel)
    } catch { check(false, "cold handoff fixture setup") }
    let model = AppModel(repository: StateRepository(url: temporary.appendingPathComponent("state.json")),
                         catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    check(wait { !model.indexing }, "handoff fixture prepares locally")
    let controller = PanelController(model: model)
    controller.currentPID = { 101 }; controller.restorePID = { _ in }
    var requests: [SearchHandoff] = []
    var completion: ((Bool) -> Void)?
    controller.dispatchSearch = { request, callback in requests.append(request); completion = callback }
    defer { controller.dismiss(.cancel) }
    func event(_ modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: repeated, keyCode: 48)!
    }
    let query = "  piano & café 🎹 "
    var modes: [AppModel.Mode] = []
    let modeObserver = model.$mode.dropFirst().sink { modes.append($0) }
    controller.receiveSearch(SearchHandoff(query: query, returnPID: 101), orderFront: false)
    check(!modes.contains(.compass) && modes.contains(.search), "handoff mounts search directly without a compass layout")
    modeObserver.cancel()
    check(controller.panel.frame.size == SpleenStyle.managementSize, "handoff presents at the final search size")
    check(wait { controller.panel.firstResponder is NSTextView }, "incoming handoff mounts the search editor")
    check(model.mode == .search && model.query == query, "incoming handoff preserves query and opens conversation search")
    let editor = controller.panel.firstResponder as? NSTextView
    check(editor?.selectedRange() == NSRange(location: (query as NSString).length, length: 0), "incoming caret is at the end")
    check(controller.handleKeyDown(event(.control)) != nil && requests.isEmpty, "Control Tab stays native")
    _ = controller.handleKeyDown(event(repeated: true))
    check(requests.isEmpty, "repeated Tab cannot bounce")
    editor?.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check(controller.handleKeyDown(event()) != nil && requests.isEmpty, "composing input keeps Tab")
    editor?.unmarkText()
    controller.receiveSearch(SearchHandoff(query: query, returnPID: 101), orderFront: false)
    _ = controller.handleKeyDown(event())
    check(requests.last == SearchHandoff(query: query, returnPID: 101) && !controller.session.isPresented, "outgoing Tab carries the query and original return app")
    completion?(false)
    check(controller.session.isPresented && model.query == query && model.error != nil && controller.session.priorPID == 101,
          "failed handoff preserves search and cancellation target")
    _ = controller.handleKeyDown(event(.shift))
    let oldCompletion = completion
    controller.receiveSearch(SearchHandoff(query: "new query", returnPID: 101), orderFront: false)
    oldCompletion?(true)
    check(controller.session.isPresented && model.query == "new query", "late acceptance cannot close a new incoming search")
    _ = controller.handleKeyDown(event())
    completion?(true)
    check(!controller.session.isPresented, "accepted handoff ends the source presentation")
    controller.receiveSearch(SearchHandoff(query: "", returnPID: 101), orderFront: false)
    check(model.query.isEmpty && model.mode == .search, "empty incoming query clears stale text")
    model.showSettings()
    let before = requests.count
    check(controller.handleKeyDown(event()) != nil && requests.count == before, "settings retains native Tab focus")
    controller.dismiss(.cancel)
    controller.present(orderFront: false, assessOnOpen: false)
    _ = controller.handleKeyDown(event())
    check(requests.last?.query == "" && requests.count == before + 1, "Tab also switches from the empty compass")
    completion?(true)
    return (count - failures.count, failures)
}
