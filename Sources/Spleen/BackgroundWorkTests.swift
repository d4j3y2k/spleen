import AppKit
import Combine
import SpleenCore

/// While live sources keep re-reporting the same facts, the app should do no work:
/// no snapshot rebuild, no SwiftUI invalidation, and no blinking timer behind a hidden panel.
func runBackgroundWorkTests() -> (passed: Int, failures: [String]) {
    var passed = 0, failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if condition { passed += 1 } else { failures.append(label); print("FAIL: \(label)") } }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        return condition()
    }
    func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-background-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let working = Destination(title: "Working session", threadID: "thr_background_working")
        let other = Destination(title: "Other session", threadID: "thr_background_other")
        var state = SavedState(); state.destinations = [working, other]
        let repository = StateRepository(url: directory.appendingPathComponent("destinations.json")); try repository.save(state)
        let model = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] })
        check(wait { !model.indexing }, "background fixture prepares")
        var sequence: UInt64 = 0
        func report(_ activity: RuntimeActivity?) {
            sequence += 1
            model.receiveClaudeStatus(LiveSessionState(key: working.conversationKey, source: ClaudeDesktopStatus.source, epoch: "fixture",
                observedAt: Date(), lifetime: 8, sequence: sequence, activity: activity, isUnread: false))
        }
        report(.working)
        check(wait { !model.indexing }, "first status settles")
        var publishes = 0
        let subscription = model.objectWillChange.sink { publishes += 1 }
        defer { subscription.cancel() }
        let builds = model.snapshotBuildCount
        for _ in 0..<5 { report(.working) }
        spin(0.3)
        check(model.snapshotBuildCount == builds, "re-reported Claude status does not rebuild the snapshot")
        check(publishes == 0, "re-reported Claude status does not re-render the panel")
        check(model.liveState(working)?.activity == .working, "re-reported status stays live")
        report(nil)
        check(wait { model.snapshotBuildCount > builds }, "a changed status rebuilds")
        check(publishes > 0, "a changed status re-renders")
        check(wait { !model.indexing }, "changed status settles")

        // The working dot blinks only while the panel is on screen.
        report(.working)
        check(wait { !model.indexing }, "working status settles")
        let controller = PanelController(model: model)
        let own = ProcessInfo.processInfo.processIdentifier
        controller.currentPID = { own }; controller.restorePID = { _ in }; controller.dispatchURL = { _ in true }
        let baseline = WorkingDotDiagnostics.activeTimers
        controller.present()
        spin(0.3)
        if controller.panel.occlusionState.contains(.visible) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(WorkingDotDiagnostics.activeTimers > baseline, "working dot blinks while the panel is shown")
        } else {
            print("Working-dot blink while shown not checked: the panel was not on screen, or Reduce Motion is on.")
        }
        controller.dismiss(.cancel)
        check(wait { WorkingDotDiagnostics.activeTimers == baseline }, "working dot stops blinking when the panel is hidden")
    } catch { check(false, "background work fixture error: \(error.localizedDescription)") }
    return (passed, failures)
}
