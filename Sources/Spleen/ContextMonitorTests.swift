import Foundation
import SpleenCore

/// Watches only disposable app-owned files; no provider process or external UI.
func runContextMonitorTests() -> (passed: Int, failures: [String]) {
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-monitor-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("fresh/nested-store")
    let counter = ContextMonitorCounter()
    let monitor = ContextMonitor(directory: directory) { counter.increment() }
    check(monitor != nil && FileManager.default.fileExists(atPath: directory.path),
          "context watcher creates a fresh store without waiting for catalog persistence")
    check(wait { counter.value == 1 }, "watcher performs one initial reconciliation for the load-before-watch gap")
    do {
        for index in 0..<40 {
            try Data("unrelated \(index)".utf8).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
            try Data("unrelated \(index)".utf8).write(to: directory.appendingPathComponent("relevance.json"), options: .atomic)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(counter.value == 1, "catalog and insight write bursts do not trigger context reloads")
        let repository = ContextRepository(url: directory.appendingPathComponent("context.json"))
        let first = ContextEvent(key: ConversationKey(provider: .codex, id: "thr_monitor_first"),
                                 kind: .spleenDispatch, source: "offline-monitor", evidence: .spleenInteraction)
        try repository.record(first)
        check(wait { counter.value == 2 }, "atomic first context creation is observed")
        let original = try Data(contentsOf: repository.url)
        try original.write(to: repository.url, options: .atomic)
        check(wait { counter.value == 3 }, "equal-sized atomic context replacement is observed by file identity")
        for index in 0..<20 {
            try Data("preference \(index)".utf8).write(to: directory.appendingPathComponent("context-settings.json"), options: .atomic)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(counter.value == 3, "preference write bursts do not masquerade as context changes")
        try FileManager.default.removeItem(at: repository.url)
        check(wait { counter.value == 4 }, "context removal triggers reconciliation")
        try original.write(to: repository.url, options: .atomic)
        check(wait { counter.value == 5 }, "context recreation remains observed")
        withExtendedLifetime(monitor) {}
    } catch { check(false, "context monitor fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}

private final class ContextMonitorCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
