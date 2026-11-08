import AppKit
import SpleenCore

/// Uses an isolated store and injected opener; no external app or Dot is opened.
func runDotTests() -> (passed: Int, failures: [String]) {
    var count = 0, failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-dot-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = StateRepository(url: directory.appendingPathComponent("destinations.json"))
    let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
    let controller = PanelController(model: model)
    controller.currentPID = { ProcessInfo.processInfo.processIdentifier }
    var urls: [URL] = []
    controller.dispatchURL = { urls.append($0); return true }
    controller.present(orderFront: false)
    controller.openDot()
    check(model.mode == .settings && urls.isEmpty, "unconfigured Dot opens settings without dispatch")
    model.dotLinkDraft = "codex://threads/new"
    model.saveSettings()
    check(model.mode == .settings && model.error != nil && model.dotURL == nil, "invalid Dot setting is retained without saving")
    let link = "codex://threads/thr_dot_fixture?hostId=durable"
    model.dotLinkDraft = link
    model.saveSettings()
    check(model.dotURL?.absoluteString == link && (try? repository.load().dotLink) == link,
          "Dot setting persists its cloud host")
    controller.dismiss(.cancel)
    controller.present(orderFront: false)
    func key(_ character: String, modifiers: NSEvent.ModifierFlags, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: repeated, keyCode: 2)!
    }
    _ = controller.handleKeyDown(key("d", modifiers: .command, repeated: true))
    check(urls.isEmpty && controller.session.isPresented, "repeated Dot shortcut cannot dispatch")
    let handled = controller.handleKeyDown(key("d", modifiers: .command))
    check(handled == nil && urls.map(\.absoluteString) == [link] && !controller.session.isPresented,
          "Command-D dispatches the exact Dot link and dismisses Spleen")
    check(model.state.destinations.isEmpty, "Dot dispatch does not enter local ranking or recents")
    controller.openDot()
    check(urls.count == 2, "menu-bar Dot action works with the panel closed")
    controller.dispatchURL = { _ in false }
    controller.openDot()
    check(controller.session.isPresented && model.error != nil && model.dotURL?.absoluteString == link,
          "rejected Dot dispatch shows a recoverable error and preserves its link")
    controller.dismiss(.cancel)
    model.showSettings(); model.dotLinkDraft = ""; model.saveSettings()
    check(model.dotURL == nil && (try? repository.load())?.dotLink == nil, "clearing the Dot setting removes the shortcut target")
    return (count - failures.count, failures)
}
