import AppKit
import SpleenCore

/// Exercises only a hidden, app-owned panel; no external focus or input is sent.
func runKeyboardReadinessTests() -> (passed: Int, failures: [String]) {
    var count = 0
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        return predicate()
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-key-readiness-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let repository = StateRepository(url: directory.appendingPathComponent("state.json"))
        var state = SavedState()
        state.destinations = [Destination(title: "Écriture", threadID: "thr_keyboard_readiness")]
        try repository.save(state)
        let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !model.indexing }, "dead-key fixture snapshot is ready")
        let controller = PanelController(model: model)
        var dispatches = 0
        controller.currentPID = { nil }
        controller.restorePID = { _ in }
        controller.dispatchURL = { _ in dispatches += 1; return true }
        defer { controller.dismiss(.cancel) }
        func event(_ code: UInt16, characters: String, plain: String, modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: plain,
                isARepeat: repeated, keyCode: code)!
        }
        let deadKey = event(14, characters: "", plain: "e", modifiers: .option)
        check(PanelController.startsSearch(deadKey), "empty-character Option dead key enters search")
        check(!PanelController.startsSearch(event(123, characters: "", plain: "\u{F702}", modifiers: .option)),
              "Option navigation without printable text does not enter search")
        check(!PanelController.startsSearch(event(14, characters: "", plain: "e", modifiers: [.option, .control])),
              "Control-Option empty-character events cannot enter search")
        check(!PanelController.startsSearch(event(14, characters: "", plain: "e", modifiers: .option, repeated: true)),
              "repeated empty-character events cannot enter search")
        check(PanelController.startsSearch(event(14, characters: "É", plain: "E", modifiers: .shift)),
              "Shift printable input remains available")
        controller.present(orderFront: false)
        controller.handleKeyDown(deadKey)
        check(model.mode == .search && !controller.panel.isVisible && dispatches == 0,
              "first dead key transitions the hidden native panel without dispatch")
        check(wait { controller.panel.firstResponder is NSTextView }, "dead-key replay mounts native input responder")
        if let editor = controller.panel.firstResponder as? NSTextView {
            // Layout/input-source-specific accent composition stays AppKit's job;
            // this verifies preserved marked-text routing without changing layout.
            editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            check(controller.handleKeyDown(event(36, characters: "\r", plain: "\r")) != nil && dispatches == 0,
                  "composing native field receives Enter without dispatch")
            check(controller.handleKeyDown(event(53, characters: "\u{1B}", plain: "\u{1B}")) != nil && controller.session.isPresented,
                  "composing native field receives Escape without dismissing")
            editor.unmarkText()
        }
        // Focused controls must receive activation instead of opening an unrelated
        // selected chat. This hidden button requires no system keyboard preference.
        let action = ReadinessActionButton(title: "Settings", target: nil, action: nil)
        controller.panel.contentView?.addSubview(action)
        check(controller.panel.makeFirstResponder(action), "hidden management button accepts native focus")
        let beforeControlKeys = dispatches
        for code in [UInt16(36), UInt16(76), UInt16(49)] {
            if let forwarded = controller.handleKeyDown(event(code, characters: code == 49 ? " " : "\r", plain: code == 49 ? " " : "\r")) {
                action.keyDown(with: forwarded)
            }
        }
        check(action.activations == 3 && dispatches == beforeControlKeys,
              "focused search control receives Return, keypad Enter, and Space without chat dispatch")
        check(controller.handleKeyDown(event(125, characters: "\u{F701}", plain: "\u{F701}")) != nil,
              "focused management control retains arrow navigation")
        controller.dismiss(.cancel)
        controller.present(orderFront: false)
        controller.panel.contentView?.addSubview(action)
        check(controller.panel.makeFirstResponder(action), "hidden compass control accepts native focus")
        if let forwarded = controller.handleKeyDown(event(49, characters: " ", plain: " ")) {
            action.keyDown(with: forwarded)
        }
        check(action.activations == 4 && dispatches == beforeControlKeys,
              "focused native control on compass receives Space without dispatching selected chat")
        action.removeFromSuperview()
        controller.panel.makeFirstResponder(controller.panel.contentView)
        check(controller.handleKeyDown(event(49, characters: " ", plain: " ")) == nil && dispatches == beforeControlKeys + 1,
              "ordinary compass canvas retains immediate Space confirmation")
        controller.dismiss(.cancel)

        // A presentation can close and reopen before SwiftUI unmounts its old
        // editor. The first confirmation must not be swallowed by old IME state.
        controller.present(orderFront: false)
        controller.handleKeyDown(event(14, characters: "e", plain: "e"))
        check(wait { model.mode == .search && controller.panel.firstResponder is NSTextView },
              "rapid-reopen fixture has a mounted native search editor")
        if let editor = controller.panel.firstResponder as? NSTextView {
            editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.dismiss(.cancel)
            check(!editor.hasMarkedText() && controller.panel.firstResponder !== editor,
                  "dismiss releases native composition and stale editor focus synchronously")
            controller.present(orderFront: false)
            let beforeImmediateOpen = dispatches
            controller.handleKeyDown(event(49, characters: " ", plain: " "))
            check(dispatches == beforeImmediateOpen + 1 && !controller.session.isPresented,
                  "immediate reopen accepts first Space before old editor unmounts")
        }

        // Reparenting a native field before its deferred readiness callback must
        // not produce two competing focus requests on the next run-loop turn.
        let attachmentWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        attachmentWindow.isReleasedWhenClosed = false
        defer { attachmentWindow.close() }
        let attachmentRoot = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        attachmentWindow.contentView = attachmentRoot
        let reattachedField = SearchTextField(frame: attachmentRoot.bounds)
        var readinessCallbacks = 0
        reattachedField.ready = { _ in readinessCallbacks += 1 }
        attachmentRoot.addSubview(reattachedField)
        reattachedField.removeFromSuperview()
        attachmentRoot.addSubview(reattachedField)
        check(wait { readinessCallbacks > 0 }, "reattached native field eventually reports readiness")
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        check(readinessCallbacks == 1, "stale attachment callbacks cannot reclaim input focus twice")

        controller.present(orderFront: false)
        model.beginSearch("Écriture")
        let reopenedSelection = model.selectedID
        controller.present(reset: true, orderFront: true)
        check(controller.panel.isVisible && controller.session.isPresented,
              "reopening a presented nonkey panel brings the existing panel forward")
        check(model.mode == .search && model.query == "Écriture" && model.selectedID == reopenedSelection,
              "reopening a nonkey panel preserves search and selection")
        controller.dismiss(.cancel)

        let emptyRepository = StateRepository(url: directory.appendingPathComponent("empty/state.json"))
        try emptyRepository.save(SavedState())
        let emptyModel = AppModel(repository: emptyRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !emptyModel.indexing }, "empty keyboard fixture snapshot is ready")
        let empty = PanelController(model: emptyModel)
        empty.currentPID = { nil }
        empty.restorePID = { _ in }
        empty.dispatchURL = { _ in dispatches += 1; return true }
        defer { empty.dismiss(.cancel) }
        empty.present(orderFront: false)
        let emptyBefore = dispatches
        for code in [UInt16(36), UInt16(76), UInt16(49)] {
            let text = code == 49 ? " " : "\r"
            check(empty.handleKeyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: empty.panel.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!) != nil && dispatches == emptyBefore,
                  "empty compass passes activation key \(code) to its native Add action")
        }
    } catch { check(false, "keyboard readiness fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}

private final class ReadinessActionButton: NSButton {
    var activations = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { activations += 1 }
        else { super.keyDown(with: event) }
    }
}
