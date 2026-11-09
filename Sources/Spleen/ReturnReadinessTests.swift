import Foundation
import SpleenCore

/// Hold background work to exercise immediate reopening, rather than waiting
/// for ranking to settle before every simulated jump.
func runReturnReadinessTests() -> (passed: Int, failures: [String]) {
    var count = 0, failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    @discardableResult func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return condition()
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-immediate-return-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ReturnTestClock()
    let a = Destination(title: "Codex A", threadID: "thr_immediate_a", lastOpenedAt: clock.wall.addingTimeInterval(-60))
    let b = Destination(title: "Codex B", threadID: "thr_immediate_b")
    let urgent = Destination(title: "Needs approval", threadID: "thr_immediate_urgent")
    let pin = Destination(title: "Reference", threadID: "thr_immediate_pin", pinned: true)
    let claude = Destination(title: "Older Claude visit", threadID: "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef", provider: .claude)
    func seed(_ directory: URL) throws -> StateRepository {
        let repository = StateRepository(url: directory.appendingPathComponent("state.json"))
        var state = SavedState(); state.version = 3; state.destinations = [pin, a, b, urgent, claude]
        try repository.save(state)
        let store = ContextRepository(url: directory.appendingPathComponent("context.json"))
        try store.record(ContextEvent(key: claude.conversationKey, topic: claude.title, kind: .selectedConversation,
            observedAt: clock.wall.addingTimeInterval(-120), source: "claude-desktop-accessibility", evidence: .observedSelection), now: clock.wall)
        try store.record(ContextEvent(key: a.conversationKey, kind: .spleenDispatch,
            observedAt: clock.wall.addingTimeInterval(-60), source: "spleen", evidence: .spleenInteraction), now: clock.wall)
        return repository
    }
    do {
        let builder = ReturnTestBuilder()
        let model = AppModel(repository: try seed(root.appendingPathComponent("rapid")),
            catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] },
            now: { clock.wall }, uptime: { clock.tick }, snapshotBuilder: builder.build)
        check(wait { !model.indexing }, "immediate-return fixture prepares")
        model.prepare()
        builder.blockNext()
        model.endPresentation(); clock.advance()
        model.acceptedDispatch(b.id)
        check(wait { builder.blocked }, "ranking is deliberately held during rapid navigation")
        model.prepare()
        check(model.compassItems.first?.id == a.id && model.selectedID == a.id,
            "Codex A is immediately centered after A to B, without waiting for ranking")
        check(model.compassItems.first?.id != claude.id, "older Claude visit cannot retain the initial center after two Codex selections")
        for (target, previous) in [(a, b), (b, a), (a, b)] {
            model.endPresentation(); clock.advance()
            model.acceptedDispatch(target.id)
            model.prepare()
            check(model.indexing && model.compassItems.first?.id == previous.id,
                "rapid successive dispatch immediately returns to \(previous.title)")
        }
        model.receiveLiveState(LiveSessionState(key: urgent.conversationKey, source: "fixture", observedAt: clock.wall,
            sequence: 1, activity: .waitingForApproval, isUnread: nil))
        builder.release.signal()
        check(wait { !model.indexing }, "latest ranking completes after superseded rapid jumps")
        check(model.compassItems.first?.id == urgent.id && model.selectedID == urgent.id,
            "untouched initial previous-session choice refines to the higher-priority candidate")
        model.endPresentation(); model.prepare()
        check(model.compassItems.first?.id == b.id, "even with ranking ready, opening starts with the previous conversation")
        check(wait { model.compassItems.first?.id == urgent.id }, "cached ranking refines on a later UI turn without a new request")

        for search in [false, true] {
            builder.blockNext()
            model.endPresentation(); clock.advance()
            model.acceptedDispatch(b.id)
            check(wait { builder.blocked }, "refinement freeze fixture holds background work")
            model.prepare()
            if search { model.beginSearch("Codex") } else { model.move(1); model.move(-1) }
            let choices = model.compassItems, results = model.results, selected = model.selectedID
            builder.release.signal()
            check(wait { !model.indexing }, "refinement freeze fixture finishes ranking")
            check(model.compassItems == choices && model.results == results && model.selectedID == selected,
                search ? "typing freezes the initial invocation" : "navigation freezes even after returning selection to center")
            // Alternate back, including selecting from filtered search results.
            model.endPresentation(); clock.advance(); model.acceptedDispatch(a.id)
            model.prepare()
            check(model.compassItems.first?.id == b.id, "search-based dispatch retains the prior conversation outside filtered results")
            check(wait { !model.indexing }, "return after freeze case settles")
        }
        // Both same-app and cross-app rapid returns use the same immediate path.
        model.endPresentation(); clock.advance(); model.acceptedDispatch(claude.id); model.prepare()
        check(model.compassItems.first?.id == a.id, "Codex to Claude immediately offers the prior Codex session")
        model.endPresentation(); clock.advance(); model.acceptedDispatch(b.id); model.prepare()
        check(model.compassItems.first?.id == claude.id, "Claude to Codex immediately offers the prior Claude session")
        check(wait { !model.indexing }, "cross-app return fixture settles")
        // Returning to Claude by hand and opening within the visit dwell: the fronted
        // chat is already current, so the just-left Codex thread stays centered and
        // the fronted chat does not take a quick-return slot. No visit is recorded.
        model.endPresentation(); clock.advance(); model.receiveForeground(claude.conversationKey); model.prepare()
        check(model.compassItems.first?.id == b.id, "fronted Claude chat within the dwell centers the just-left Codex thread")
        check(!model.compassItems.prefix(2).contains(where: { $0.id == claude.id }), "fronted chat does not take a quick-return slot before its visit is recorded")
        check(model.context.currentHint(at: clock.wall)?.key == b.conversationKey, "a foreground report alone records no interaction")
        check(wait { !model.indexing }, "foreground fixture settles")
        let settled = model.compassItems.map(\.id)
        check((settled.firstIndex(of: b.id) ?? 9) < (settled.firstIndex(of: a.id) ?? 9),
            "just-left Codex thread outranks the older interaction once the snapshot settles: \(model.compassItems.map(\.title))")
        check(model.compassItems.last?.id == claude.id, "fronted chat ranks last once the snapshot settles, still without a recorded visit")
        // Switching to an unobserved application by hand: nothing is current, so the
        // conversation that would have been hidden is offered as a return target.
        model.endPresentation(); clock.advance(); model.receiveFrontApplication(.other)
        check(wait { !model.indexing }, "front-application fixture settles")
        model.prepare()
        let unhidden = model.compassItems.map(\.id)
        check((unhidden.firstIndex(of: b.id) ?? 9) < (unhidden.firstIndex(of: a.id) ?? 9),
            "recorded order holds while another application is in front: \(model.compassItems.map(\.title))")
        check(model.context.currentHint(at: clock.wall)?.key == b.conversationKey, "a front-application change records no interaction")
        model.endPresentation(); clock.advance(); model.receiveFrontApplication(.provider(.claude))
        check(wait { !model.indexing }, "front-application fixture settles again")
        model.prepare()
        check(model.compassItems.last?.id == claude.id, "the fronted chat is current again once its application is in front")
        model.endPresentation()

        let staleDirectory = root.appendingPathComponent("stale-read")
        let reader = ReturnTestContextReader()
        let stale = AppModel(repository: try seed(staleDirectory), catalogFetcher: { _ in ([], false) },
            insightFetcher: { _, _ in [] }, now: { clock.wall }, uptime: { clock.tick }, contextReader: reader.read)
        check(wait { !stale.indexing }, "stale-read fixture prepares")
        stale.prepare()
        reader.blockNext()
        clock.advance()
        try ContextRepository(url: staleDirectory.appendingPathComponent("context.json")).record(
            ContextEvent(key: claude.conversationKey, kind: .turnCompleted, observedAt: clock.wall,
                source: "fixture", evidence: .lifecycle), now: clock.wall)
        check(wait { reader.blocked }, "an older context read is held before delivery")
        clock.advance(); stale.endPresentation(); stale.acceptedDispatch(b.id); stale.prepare()
        reader.release.signal()
        check(wait { reader.finished }, "older context read returns after the local dispatch")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(stale.context.currentHint(at: clock.wall)?.key == b.conversationKey,
            "delayed context read cannot overwrite the newest accepted dispatch")
        check(stale.context.previousDistinct(at: clock.wall)?.key == a.conversationKey,
            "delayed context read cannot resurrect the older Claude return target")
        check(wait { !stale.indexing }, "stale-read ranking settles")
        stale.endPresentation()
    } catch { check(false, "immediate-return fixture error: \(error.localizedDescription)") }
    return (count - failures.count, failures)
}

private final class ReturnTestClock {
    var wall = Date(timeIntervalSince1970: 2_000_000_000)
    var tick = 100.0
    func advance() { wall = wall.addingTimeInterval(0.1); tick += 0.1 }
}

private final class ReturnTestBuilder {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hold = false
    private var waiting = false
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func blockNext() { lock.lock(); hold = true; waiting = false; lock.unlock() }
    func build(_ state: SavedState, _ catalog: CatalogCache, _ notes: [ThreadInsight], _ memory: ContextMemory,
               _ instant: Date, _ tick: TimeInterval, _ attention: SessionAttention) -> PreparedContext {
        lock.lock(); let block = hold; hold = false; waiting = block; lock.unlock()
        if block { _ = release.wait(timeout: .now() + 4) }
        return PreparedContext(state: state, catalog: catalog, insights: notes, context: memory, now: instant, uptime: tick, attention: attention)
    }
}

private final class ReturnTestContextReader {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hold = false
    private var waiting = false
    private var returned = false
    private enum TestError: Error { case disconnected }
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return returned }
    func blockNext() { lock.lock(); hold = true; lock.unlock() }
    func read(_ url: URL) throws -> ContextMemory {
        lock.lock(); let block = hold, fail = returned; hold = false; lock.unlock()
        // Keep later reconciliations from masking a stale read's transient rewind.
        if fail { throw TestError.disconnected }
        let memory = try ContextRepository(url: url).load()
        if block {
            lock.lock(); waiting = true; lock.unlock()
            _ = release.wait(timeout: .now() + 4)
            lock.lock(); returned = true; lock.unlock()
        }
        return memory
    }
}
