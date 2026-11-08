import Foundation
import SpleenCore

/// Real helper process -> atomic journal -> file watcher -> native model. Synthetic
/// provider events, never an assertion that the running Codex source sent them.
func runActivityIntegrationTests() -> (passed: Int, failures: [String]) {
    var passed = 0, failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if condition { passed += 1 } else { failures.append(label); print("FAIL: \(label)") } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-activity-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let item = Destination(title: "Activity fixture", threadID: "thr_activity_native", lastOpenedAt: Date())
        var state = SavedState(); state.destinations = [item] + (0..<8).map {
            Destination(title: "Other conversation \($0)", threadID: "thr_activity_other_\($0)")
        }
        let repository = StateRepository(url: root.appendingPathComponent("destinations.json")); try repository.save(state)
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]; catalog.refreshedAt = Date()
        catalog.entries = state.destinations.map { CatalogEntry(id: $0.threadID, title: $0.title, folder: "/fixture", updatedAt: Date()) }
        try catalog.save(to: root.appendingPathComponent("catalog.json"))
        let journal = ActivityHookRepository(url: root.appendingPathComponent("activity-hooks.json"))
        _ = try journal.setEnabled(true)
        let model = AppModel(repository: repository, catalogFetcher: { _ in (catalog.entries, false) }, insightFetcher: { _, _ in [] })
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        }
        wait { !model.indexing }; model.prepare(); let fixed = model.compassItems
        check(!fixed.contains(item), "last-selected thread begins outside crowded compass without live attention")
        func send(_ payload: [String: Any], notification: Bool = false) throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [notification ? "--activity-notification" : "--activity-event", "codex", "--data-dir", root.path]
            let input = Pipe(); child.standardInput = input; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            if notification { child.arguments?.append(String(decoding: data, as: UTF8.self)) }
            try child.run()
            if !notification { try input.fileHandleForWriting.write(contentsOf: data) }
            try input.fileHandleForWriting.close(); child.waitUntilExit()
            check(child.terminationStatus == 0, "activity helper exits without disrupting source")
        }
        try send(["hook_event_name":"PreModelRequest", "session_id":item.threadID, "cwd":"/fixture", "turn_id":"turn_fixture"])
        wait { model.liveState(item)?.activity == .working }
        check(model.liveState(item)?.activity == .working, "helper event reaches native working badge through watcher")
        check(model.compassItems == fixed, "activity helper cannot move open compass cards")
        wait { !model.indexing }
        model.endPresentation(); model.prepare()
        check(model.compassItems.contains(item), "last-selected working thread becomes visible on next opening")
        check(model.liveState(item)?.accessibilityText.contains("Working") == true, "promoted working thread retains its accessible badge")
        try send(["type":"agent-turn-complete", "thread-id":item.threadID, "turn-id":"turn_fixture", "cwd":"/fixture"] , notification: true)
        wait { model.liveState(item)?.completion?.turnID == "turn_fixture" }
        check(model.liveState(item)?.completion?.turnID == "turn_fixture", "real notification helper path records exact completed turn")
        check(model.liveState(item)?.activity == nil && model.liveState(item)?.isUnread == nil, "notification never fabricates runtime idle or read state")
        _ = try journal.setEnabled(false)
        wait { model.liveState(item) == nil }
        check(model.liveState(item) == nil, "disabling activity reports disconnects native badges")
        _ = try journal.setEnabled(true)
        let activityTime = Date()
        _ = try journal.record(ActivityHookEvent(key: item.conversationKey, project: "/fixture", kind: .preModelRequest,
            turnID: "turn_quiet_fixture", receivedAt: activityTime), now: activityTime)
        let quietTime = activityTime.addingTimeInterval(20)
        let reopened = AppModel(repository: repository, catalogFetcher: { _ in (catalog.entries, false) },
                                insightFetcher: { _, _ in [] }, now: { quietTime }, uptime: { 100 })
        wait { reopened.attention.recentActivityAt(for: item.conversationKey, at: quietTime) != nil && !reopened.indexing }
        reopened.prepare()
        check(reopened.compassItems.contains(item), "restarted native app retains recently active work after the hook pulse expires")
        check(reopened.liveState(item) == nil, "quiet-turn retention does not fabricate a working spinner")
        _ = try journal.setEnabled(false)
        wait { reopened.attention.recentActivityAt(for: item.conversationKey, at: quietTime) == nil }
        check(reopened.attention.recentActivityAt(for: item.conversationKey, at: quietTime) == nil,
              "disabling hooks clears activity history as well as live state")
    } catch { failures.append("activity integration fixture: \(error)") }
    return (passed, failures)
}
