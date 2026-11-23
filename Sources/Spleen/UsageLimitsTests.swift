import AppKit
import SpleenCore

/// Usage Limits inside the built app: injected clock, fetchers, timer and wake; keyboard
/// events posted to the application so they pass through the real local key monitor; and
/// one real stand-in helper to prove close, mode switch, focus loss and quit reap it. Every
/// reading is invented. No provider client is launched.
func runUsageLimitsTests() -> (passed: Int, failures: [String]) {
    var count = 0
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        count += 1
        if !condition() { failures.append(label); print("FAIL: \(label)") }
    }
    func spin(_ seconds: TimeInterval = 0.02) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: end) }
    }
    func wait(_ seconds: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        return predicate()
    }

    // MARK: Fakes

    final class Clock { var now = Date(timeIntervalSince1970: 1_900_000_000) }
    final class Timers {
        var scheduled: [(date: Date, fire: () -> Void, cancelled: Bool)] = []
        func schedule(_ date: Date, _ fire: @escaping () -> Void) -> () -> Void {
            scheduled.append((date, fire, false)); let index = scheduled.count - 1
            return { [weak self] in self?.scheduled[index].cancelled = true }
        }
        var live: [(date: Date, fire: () -> Void, cancelled: Bool)] { scheduled.filter { !$0.cancelled } }
        func fireLive() { for entry in live { entry.fire() } }
    }
    final class Wake {
        var handlers: [Int: () -> Void] = [:]; var next = 0
        func observe(_ handler: @escaping () -> Void) -> () -> Void {
            next += 1; let key = next; handlers[key] = handler
            return { [weak self] in self?.handlers[key] = nil }
        }
        func trigger() { for handler in handlers.values { handler() } }
    }
    final class Fetcher {
        var requests: [UsageFetchRequest] = []
        var fetch: UsageFetch { { [unowned self] in self.requests.append($0) } }
        func finish(_ result: Result<UsageReading, UsageProblem>, _ index: Int? = nil) {
            requests[index ?? requests.count - 1].emit(.finished(result))
        }
        func identity(_ identity: UsageIdentity, _ index: Int? = nil) { requests[index ?? requests.count - 1].emit(.identity(identity)) }
    }
    struct Rig { let model: UsageLimitsModel; let clock: Clock; let timers: Timers; let wake: Wake; let codex: Fetcher; let claude: Fetcher; var shutdowns: () -> Int }
    func rig() -> Rig {
        let clock = Clock(), timers = Timers(), wake = Wake(), codex = Fetcher(), claude = Fetcher()
        var shutdowns = 0
        let model = UsageLimitsModel(clock: { clock.now }, fetchers: [.codex: codex.fetch, .claude: claude.fetch],
                                     scheduleTimer: timers.schedule, observeWake: wake.observe, shutdown: { shutdowns += 1 })
        return Rig(model: model, clock: clock, timers: timers, wake: wake, codex: codex, claude: claude, shutdowns: { shutdowns })
    }
    let personA = UsageIdentity.known(UsagePerson(key: "fixture-a")), personB = UsageIdentity.known(UsagePerson(key: "fixture-b"))
    func reading(_ owner: UsageIdentity = .unknown, resets: [TimeInterval?] = [3600], at instant: Date, used: Double = 30) -> UsageReading {
        UsageReading(windows: resets.enumerated().map { UsageWindow(id: "w\($0.offset)", label: "Weekly limit", usedPercent: used,
                                                                    resetsAt: $0.element.map { instant.addingTimeInterval($0) }) },
                     checkedAt: .distantPast, owner: UsageOwner(user: owner))
    }

    // MARK: Model

    do {
        let r = rig(), m = r.model
        m.open()
        check(m.status(.codex) == .loading && m.status(.claude) == .loading, "first use shows loading for both providers synchronously")
        check(r.codex.requests.count == 1 && r.claude.requests.count == 1, "an opening refreshes both providers")
        r.codex.finish(.success(reading(at: r.clock.now))); spin()
        check(m.status(.codex) == .checked(r.clock.now) && m.status(.claude) == .loading,
              "Codex is readable while Claude is still loading")
        for failure in [UsageFailure.timeout, .signedOut, .missingClient, .incompatible, .offlineOrEmpty] {
            m.close(); m.open()
            r.claude.finish(.failure(UsageProblem(failure))); spin()
            check(m.state(.codex).reading != nil, "a Claude \(failure) leaves Codex usable")
        }
        let firstChecked = m.state(.codex).reading?.checkedAt
        m.close(); r.clock.now += 120; m.open()
        check(m.status(.codex) == .checking(lastKnown: firstChecked!), "the cached reading is painted synchronously on open")
        r.codex.finish(.failure(UsageProblem(.offlineOrEmpty))); spin()
        check(m.status(.codex) == .lastKnown(firstChecked!, .offlineOrEmpty), "a failed refresh keeps the reading and its original timestamp")
        check(m.status(.claude) == .loading && m.state(.claude).lastFailure == .offlineOrEmpty, "Claude's earlier failure is kept while it checks again")
        let fresh = rig(); fresh.model.open(); fresh.claude.finish(.failure(UsageProblem(.missingClient))); spin()
        check(fresh.model.status(.claude) == .unavailable(.missingClient, triedAt: fresh.clock.now), "a first-use failure shows the attempt time")

        // Coalescing and backoff.
        let c = rig(); c.model.open()
        c.model.refresh(.codex); c.model.refreshAll()
        check(c.codex.requests.count == 1 && c.claude.requests.count == 1, "duplicate in-flight requests are coalesced")
        c.codex.finish(.failure(UsageProblem(.offlineOrEmpty, retryAfter: c.clock.now + 60))); spin()
        c.model.refresh(.codex)
        check(c.codex.requests.count == 1, "manual refresh honours provider backoff")
        c.model.close(); c.model.open()
        check(c.codex.requests.count == 1 && c.claude.requests.count == 2, "an opening honours backoff for that provider only")
        c.clock.now += 61; c.model.refresh(.codex)
        check(c.codex.requests.count == 2, "refresh resumes after the backoff")

        // Stale completions and rapid close/reopen.
        let s = rig(); s.model.open()
        for _ in 0..<20 { s.model.close(); s.model.open() }
        let staleIndex = 0, currentIndex = s.codex.requests.count - 1
        s.codex.finish(.success(reading(at: s.clock.now)), staleIndex); spin()
        check(s.model.state(.codex).reading == nil && s.model.state(.codex).inFlight, "a late response from an earlier opening is ignored")
        s.codex.finish(.success(reading(at: s.clock.now)), currentIndex); spin()
        check(s.model.state(.codex).reading != nil && !s.model.state(.codex).inFlight, "the current opening's response is applied")
        s.codex.finish(.failure(UsageProblem(.timeout)), currentIndex - 1); spin()
        check(s.model.state(.codex).lastFailure == nil, "a stale completion cannot clear or fail a newer request")

        // Countdown ticks, expiry, sleep and wake are display-only.
        let e = rig(); e.model.open()
        e.codex.finish(.success(reading(resets: [100, 200], at: e.clock.now))); e.claude.finish(.failure(UsageProblem(.timeout))); spin()
        let start = e.clock.now
        check(e.model.timerTarget == start + 20, "the countdown tick targets the next whole-minute change of any reset")
        let fetchesBefore = e.model.fetchCounts
        var ticks = 0
        func advance(to goal: Date) {
            while let target = e.model.timerTarget, target <= goal { e.clock.now = target; e.timers.fireLive(); ticks += 1 }
        }
        advance(to: start + 100)
        let windows = e.model.state(.codex).reading!.windows
        check(e.model.now == start + 100 && windows[0].isExpired(at: e.model.now) && !windows[1].isExpired(at: e.model.now),
              "a reset passing while open marks that window expired at its exact instant")
        check(ticks == 4 && e.model.fetchCounts == fetchesBefore, "countdown ticks update the display and never start a read")
        check(e.model.timerTarget == start + 140, "the ticks continue for a second window expiring later")
        e.clock.now = start + 250; e.wake.trigger()
        check(windows[1].isExpired(at: e.model.now) && e.model.timerTarget == nil, "wake re-evaluates expiry after sleep; nothing left to count down")
        check(e.model.fetchCounts == fetchesBefore, "expiry and wake never start a read")
        e.model.refresh(.codex); e.clock.now += 3600
        e.codex.finish(.success(reading(resets: [60], at: start + 250))); spin()
        check(e.model.state(.codex).reading!.windows[0].isExpired(at: e.model.now) && e.model.timerTarget == nil &&
              e.model.fetchCounts[.codex] == fetchesBefore[.codex]! + 1, "a pre-sleep reply arriving after its reset stays expired and causes no retry")
        e.model.refresh(.codex); e.codex.finish(.success(reading(resets: [3600], at: e.clock.now))); spin()
        check(e.model.hasTimer, "an open view with a future reset keeps its countdown running")
        e.model.close()
        check(!e.model.hasTimer && !e.model.hasWakeObserver && !e.model.hasOutstandingWork && e.wake.handlers.isEmpty && e.timers.live.isEmpty,
              "closing leaves no timer, wake observer or outstanding request")
        let closedCounts = e.model.fetchCounts, closedNow = e.model.now
        e.clock.now += 30 * 86_400; e.timers.scheduled.forEach { $0.fire() }; e.wake.trigger()
        check(e.model.fetchCounts == closedCounts && e.model.now == closedNow,
              "after close nothing ticks and no usage request starts, however far the clock advances")

        // Row text: the provider's exact instant, a countdown beside it, nothing invented.
        let pacific = UsageTimeFormat(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        let rowNow = Date(timeIntervalSince1970: 1_795_526_400) // Tue 24 Nov 2026 13:20 UTC
        let exact = UsageWindow(id: "x", label: "Weekly limit · Fixture", usedPercent: 16, resetsAt: Date(timeIntervalSince1970: 1_795_561_199.915))
        func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }
        check(plain(UsageText.reset(exact, now: rowNow, format: pacific)) == "Resets Tue, Nov 24 at 2:59 PM" &&
              UsageText.countdown(exact, now: rowNow, format: pacific) == "in 9 h 39 min", "a row shows the exact local reset and how long from now")
        check(plain(UsageText.spoken(exact, provider: .claude, now: rowNow, format: pacific)) ==
              "Claude, weekly limit, Fixture, 84 percent left, resets Tuesday, November 24 at 2:59 PM, in 9 hours 39 minutes",
              "the row's accessibility label speaks the exact reset and the countdown")
        check(plain(pacific.precise(exact.resetsAt!))?.contains("2:59:59") == true, "the tooltip and accessibility value carry seconds and time zone")
        let passed = Date(timeIntervalSince1970: 1_795_561_260)
        check(plain(UsageText.reset(exact, now: passed, format: pacific)) == "Reset passed Tue, Nov 24 at 2:59 PM · waiting for a new reading" &&
              UsageText.countdown(exact, now: passed, format: pacific) == nil, "an expired row says exactly when its reset passed")
        let unknown = UsageWindow(id: "y", label: "Weekly limit", usedPercent: 16, resetsAt: nil)
        check(UsageText.reset(unknown, now: rowNow, format: pacific) == "Reset time unavailable" && UsageText.countdown(unknown, now: rowNow, format: pacific) == nil,
              "a missing reset time is never invented")

        // Identity.
        let i = rig(); i.model.open()
        i.codex.finish(.success(reading(personA, at: i.clock.now))); spin()
        i.model.close(); i.model.open(); i.codex.identity(personB); spin()
        check(i.model.state(.codex).reading == nil, "a known account change drops the cache before the read finishes")
        i.codex.finish(.failure(UsageProblem(.offlineOrEmpty))); spin()
        check(i.model.state(.codex).reading == nil && i.model.status(.codex) == .unavailable(.offlineOrEmpty, triedAt: i.clock.now),
              "cached A, known B, failed read: the cache stays dropped")
        i.model.close(); i.model.open(); i.codex.finish(.success(reading(personA, at: i.clock.now))); spin()
        i.model.close(); i.model.open(); i.codex.identity(.unknown); i.codex.finish(.failure(UsageProblem(.timeout))); spin()
        check(i.model.state(.codex).reading != nil, "an unknown identity keeps the cache")
        let checked = i.model.state(.codex).reading!.checkedAt
        i.model.close(); i.clock.now += 300; i.model.open(); i.codex.identity(personA); i.codex.finish(.failure(UsageProblem(.noSubscriptionLimits))); spin()
        check(i.model.state(.codex).reading?.checkedAt == checked && i.model.status(.codex) == .lastKnown(checked, .noSubscriptionLimits),
              "no subscription limits for the same account keeps the last-known values and timestamp")
        i.model.close(); i.model.open(); i.codex.identity(.signedOut); spin()
        check(i.model.state(.codex).reading == nil, "sign-out drops the cache")
        let u = rig(); u.model.open(); u.codex.finish(.success(reading(.unknown, at: u.clock.now))); spin()
        u.model.close(); u.model.open(); u.codex.identity(personB); spin()
        check(u.model.state(.codex).reading != nil, "a reading owned by unknown never inherits an owner, so B does not drop it")
        let q = rig(); q.model.open(); q.model.terminate()
        check(q.shutdowns() == 1 && !q.model.isOpen, "quit closes and reaps through the shutdown hook")
    }

    // MARK: Panel

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-usage-app-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalogFetches = 0
    let appClock = Clock()
    let r = rig()
    let model = AppModel(repository: StateRepository(url: directory.appendingPathComponent("state.json")), initialFolders: ["/fixture/usage"],
                         insightFetcher: { _, _ in [] }, discoveryFetcher: { _ in catalogFetches += 1; return ([], false) },
                         now: { appClock.now }, usage: r.model)
    _ = wait { !model.indexing }
    model.edit(); model.editorTitle = "Usage fixture chat"; model.editorLink = "thr_usage_fixture"; model.saveEditor()
    let controller = PanelController(model: model)
    let own = ProcessInfo.processInfo.processIdentifier
    var priorPID: Int32? = 101
    controller.currentPID = { priorPID }
    var restored: [Int32] = []
    controller.restorePID = { restored.append($0) }
    var urls: [URL] = []
    var acceptURL = true
    controller.dispatchURL = { urls.append($0); return acceptURL }
    var handoffCompletion: ((Bool) -> Void)?
    controller.dispatchSearch = { _, completion in handoffCompletion = completion }
    defer { controller.dismiss(.cancel) }

    func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = [], window: Int? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window ?? controller.panel.windowNumber, context: nil, characters: text,
                         charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    let commandU = { key(32, "u", .command) }, plainU = { key(32, "u") }, space = { key(49, " ") }
    let escape = { key(53, "\u{1B}") }, commandR = { key(15, "r", .command) }
    /// Posts to the application queue and pumps it, so events pass through the real local monitor.
    func post(_ events: NSEvent..., settle: TimeInterval = 0.25) {
        for event in events { NSApp.postEvent(event, atStart: false) }
        let end = Date().addingTimeInterval(settle)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }
    func finishReads() {
        if r.model.state(.codex).inFlight { r.codex.finish(.success(reading(personA, at: r.clock.now))) }
        if r.model.state(.claude).inFlight { r.claude.finish(.success(reading(personA, at: r.clock.now))) }
        _ = wait(1) { !r.model.state(.codex).inFlight && !r.model.state(.claude).inFlight }
    }

    controller.present(orderFront: false, assessOnOpen: false)
    post(commandU())
    check(model.mode == .usage && model.usageReturnMode == .compass && r.model.isOpen, "⌘U from the compass opens Usage Limits through the key monitor")
    post(commandU())
    check(model.mode == .compass && !r.model.isOpen && !r.model.hasTimer && !r.model.hasWakeObserver,
          "⌘U in Usage goes back, cancels its reads and stops its countdown")
    post(plainU())
    check(model.mode == .search && model.query == "u", "plain u still starts a search")
    _ = wait { controller.panel.firstResponder is NSTextView }
    post(commandU())
    check(model.mode == .usage && model.usageReturnMode == .search, "⌘U from search opens Usage Limits")
    post(commandU())
    check(model.mode == .search && model.query == "u", "⌘U back to search keeps the query")
    controller.dismiss(.cancel)

    controller.present(orderFront: false, assessOnOpen: false)
    post(plainU(), commandU())
    check(model.mode == .usage, "u then ⌘U before the next run-loop turn opens Usage")
    post(commandU())
    _ = wait { controller.panel.firstResponder is NSTextView }
    check(model.mode == .search && model.query == "u", "coming back from that burst shows exactly one u")
    controller.dismiss(.cancel)

    controller.present(orderFront: false, assessOnOpen: false)
    let dispatchesBefore = urls.count
    post(plainU(), commandU(), space())
    check(model.mode == .usage && model.query == "u" && urls.count == dispatchesBefore && controller.session.isPresented,
          "u, ⌘U, Space in one burst: Usage shown, query exactly u, no button activated")
    controller.dismiss(.cancel)

    // Composition, other windows, ⌘R, Escape.
    controller.present(orderFront: false, assessOnOpen: false)
    post(plainU())
    if wait(3, { controller.panel.firstResponder is NSTextView }), let editor = controller.panel.firstResponder as? NSTextView {
        editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(controller.handleKeyDown(commandU()) != nil && model.mode == .search, "⌘U during active composition goes to the input method")
        editor.unmarkText()
    } else { check(false, "composition fixture mounts the search editor") }
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    post(key(32, "u", .command, window: other.windowNumber))
    check(model.mode == .search, "⌘U for another window is ignored")
    other.close()
    controller.dismiss(.cancel)
    restored.removeAll()

    priorPID = 101
    controller.presentUsage(orderFront: false)
    check(controller.session.isPresented && model.mode == .usage && !model.hasPreparedInvocation && model.usageReturnMode == nil,
          "the menu item opens Usage directly without preparing a conversation snapshot")
    finishReads()
    check(r.model.hasTimer && r.model.hasWakeObserver, "the countdown runs while Usage is on screen")
    let before = r.model.fetchCounts
    post(commandR())
    check(r.model.fetchCounts[.codex] == before[.codex]! + 1 && r.model.fetchCounts[.claude] == before[.claude]! + 1, "⌘R refreshes both providers")
    post(commandR())
    check(r.model.fetchCounts[.codex] == before[.codex]! + 1, "⌘R while in flight is coalesced")
    check(controller.handleKeyDown(space()) != nil && controller.handleKeyDown(key(36, "\r")) != nil,
          "Space and Return pass to a focused Usage button")
    priorPID = own
    post(escape())
    check(!controller.session.isPresented && restored == [101] && !r.model.isOpen && !r.model.hasTimer && !r.model.hasWakeObserver,
          "Escape closes Usage, restores the prior app and leaves nothing ticking")
    priorPID = 101; restored.removeAll()
    controller.presentUsage(orderFront: false); controller.presentUsage(orderFront: false)
    check(controller.session.isPresented && model.mode == .usage, "the menu item is show-or-raise and never closes")
    priorPID = own
    post(commandU())
    check(!controller.session.isPresented && restored == [101], "⌘U on a direct opening closes it")
    priorPID = 101

    controller.present(orderFront: false, assessOnOpen: false)
    controller.presentUsage(orderFront: false)
    check(model.mode == .usage && model.usageReturnMode == .compass && model.hasPreparedInvocation, "the menu item over the compass switches in place")
    controller.dismiss(.cancel)

    // Direct openings and conversation work.
    appClock.now += 7 * 86_400
    let ordinaryBefore = catalogFetches
    controller.present(orderFront: false, assessOnOpen: false); controller.dismiss(.cancel)
    check(wait { catalogFetches == ordinaryBefore + 1 }, "an ordinary open–close still refreshes the catalog")
    appClock.now += 7 * 86_400
    let supersededBefore = catalogFetches
    controller.present(orderFront: false, assessOnOpen: false); controller.dismiss(.cancel); controller.presentUsage(orderFront: false)
    spin(0.2)
    check(catalogFetches == supersededBefore, "an opening superseded by direct Usage does no queued conversation work")
    controller.handleReopen()
    check(model.mode == .usage && !model.hasPreparedInvocation, "app reopen while Usage is visible only raises")
    controller.openDot()
    check(model.mode == .settings && model.hasPreparedInvocation && !r.model.isOpen, "direct Usage → ⌘D with no Dot → Settings with a prepared invocation")
    model.mode = .search
    check(model.results.contains { $0.title == "Usage fixture chat" }, "Settings → Back lands on a prepared search")
    controller.dismiss(.cancel)
    controller.presentUsage(orderFront: false)
    controller.receiveSearch(SearchHandoff(query: "Usage"))
    check(model.mode == .search && model.query == "Usage" && model.hasPreparedInvocation && model.results.count == 1,
          "an incoming search handoff over direct Usage gets a prepared snapshot")
    controller.dismiss(.cancel)
    controller.present(orderFront: false, assessOnOpen: false); model.beginSearch("fixture")
    controller.switchSearch()
    check(!controller.session.isPresented && handoffCompletion != nil, "outgoing handoff fixture is pending")
    controller.presentUsage(orderFront: false)
    handoffCompletion?(true); spin()
    check(controller.session.isPresented && model.mode == .usage && r.model.isOpen, "a late handoff acceptance does not disturb Usage")
    handoffCompletion?(false); spin()
    check(controller.session.isPresented && model.mode == .usage && model.error == nil, "a late handoff rejection does not disturb Usage")

    // Usage pages and rejected launches.
    model.openUsagePage?(.codex)
    check(urls.last?.absoluteString == "https://chatgpt.com/codex/settings/usage" && !controller.session.isPresented && !r.model.isOpen,
          "Codex's Open usage page dispatches the official URL and closes")
    controller.presentUsage(orderFront: false); model.openUsagePage?(.claude)
    check(urls.last?.absoluteString == "https://claude.ai/settings/usage", "Claude's Open usage page dispatches the official URL")
    acceptURL = false; priorPID = 303
    controller.presentUsage(orderFront: false); priorPID = 404
    model.openUsagePage?(.codex)
    check(controller.session.isPresented && model.mode == .usage && r.model.isOpen && model.error != nil && controller.session.priorPID == 303,
          "a rejected usage page restores Usage with its reads re-opened, the same focus target and an error")
    model.showSettings(); model.dotLinkDraft = "codex://threads/thr_usage_dot"; model.saveSettings()
    controller.dismiss(.cancel)
    controller.presentUsage(orderFront: false); controller.openDot()
    check(controller.session.isPresented && model.mode == .usage && r.model.isOpen && urls.last?.absoluteString.contains("thr_usage_dot") == true,
          "a rejected Dot launch restores Usage with its reads re-opened")
    acceptURL = true; priorPID = 101

    // Focus loss, sheets and third-app activation behave as before.
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.panel))
    check(!controller.session.isPresented && !r.model.isOpen, "focus loss closes Usage and cancels its reads")
    controller.presentUsage(orderFront: false)
    model.withModalPresentation {
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.panel))
    }
    check(controller.session.isPresented && r.model.isOpen, "an owned modal keeps Usage open")
    if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
                                                   userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        _ = wait(1) { !controller.session.isPresented }
        check(!controller.session.isPresented && !r.model.isOpen, "third-app activation closes Usage")
    }

    // Option-click recognition on a status-style button.
    let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 40, height: 24)); host.contentView = button
    func click(_ flags: NSEvent.ModifierFlags, at point: NSPoint = NSPoint(x: 10, y: 10), window: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0, windowNumber: (window ?? host).windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    check(AppDelegate.isOptionClick(click(.option), on: button), "an Option-click on the status button opens Usage")
    check(!AppDelegate.isOptionClick(click([]), on: button) && !AppDelegate.isOptionClick(click([.option, .command]), on: button) &&
          !AppDelegate.isOptionClick(click(.control), on: button) && !AppDelegate.isOptionClick(click(.option, at: NSPoint(x: 90, y: 10)), on: button) &&
          !AppDelegate.isOptionClick(click(.option, window: other), on: button),
          "ordinary, Control-, Command-Option and elsewhere clicks keep the menu")
    host.close()

    // MARK: Real helpers are reaped on close, mode switch, focus loss and quit.

    let helperDirectory = directory.appendingPathComponent("helper")
    try? FileManager.default.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
    let pidFile = helperDirectory.appendingPathComponent("pid")
    let standIn = helperDirectory.appendingPathComponent("slow-client")
    try? "#!/bin/sh\necho $$ > \(pidFile.path)\nsleep 30 &\necho $! >> \(pidFile.path)\nwait\n".write(to: standIn, atomically: true, encoding: .utf8)
    chmod(standIn.path, 0o755)
    let lane = HelperLane(label: "spleen.selftest.usage")
    let helperUsage = UsageLimitsModel(fetchers: [
        .codex: { CodexUsage.fetch(executable: { standIn }, workingDirectory: { helperDirectory }, environment: ["PATH": "/usr/bin:/bin"], lane: lane, request: $0) },
        .claude: { $0.emit(.finished(.failure(UsageProblem(.missingClient)))) }
    ], shutdown: { lane.cancelAll(); lane.waitUntilIdle(timeout: 1.5) })
    func pids() -> [pid_t] { ((try? String(contentsOf: pidFile)) ?? "").split(separator: "\n").compactMap { pid_t($0) } }
    func allGone(_ list: [pid_t]) -> Bool { wait(2) { list.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } } }
    func arm() { try? FileManager.default.removeItem(at: pidFile) }
    func helperRunning() -> [pid_t] { wait(3, { pids().count == 2 }) ? pids() : [] }
    let helperModel = AppModel(repository: StateRepository(url: directory.appendingPathComponent("helper-state.json")),
                               catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] }, usage: helperUsage)
    let helperPanel = PanelController(model: helperModel)
    helperPanel.currentPID = { nil }; helperPanel.restorePID = { _ in }; helperPanel.dispatchURL = { _ in true }
    arm(); helperPanel.presentUsage(orderFront: false)
    var running = helperRunning()
    helperPanel.dismiss(.cancel)
    check(!running.isEmpty && allGone(running) && lane.waitUntilIdle(timeout: 1), "closing the panel mid-read leaves no helper or descendant")
    helperPanel.present(orderFront: false, assessOnOpen: false); arm(); helperModel.showUsage()
    running = helperRunning()
    helperModel.leaveUsage()
    check(!running.isEmpty && allGone(running) && lane.waitUntilIdle(timeout: 1), "switching modes mid-read reaps the helper")
    helperPanel.dismiss(.cancel)
    arm(); helperPanel.presentUsage(orderFront: false); running = helperRunning()
    helperPanel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: helperPanel.panel))
    check(!running.isEmpty && allGone(running) && lane.waitUntilIdle(timeout: 1), "focus loss mid-read reaps the helper")
    arm(); helperPanel.presentUsage(orderFront: false); running = helperRunning()
    for _ in 0..<5 { helperPanel.dismiss(.cancel); helperPanel.presentUsage(orderFront: false) }
    helperPanel.dismiss(.cancel)
    check(lane.waitUntilIdle(timeout: 2) && allGone(lane.startedPIDs) && lane.maximumLiveChildren == 1,
          "rapid close and reopen never runs two helpers and reaps them all")
    arm(); helperPanel.presentUsage(orderFront: false); running = helperRunning()
    helperModel.prepareForTermination()
    check(!running.isEmpty && lane.isIdle && allGone(running) && !helperUsage.hasTimer && !helperUsage.hasWakeObserver,
          "quit reaps the helper synchronously and leaves nothing scheduled")

    return (count - failures.count, failures)
}


/// Warm, fixture-based timing: trigger to the first Core Animation commit carrying Usage
/// content (not a compositor frame). It runs inside NSApp.run, because a visible window's
/// SwiftUI updates wait for the app's display cycle, which does not exist yet while
/// applicationDidFinishLaunching is still running the synchronous self-tests.
func runUsageTimingTrials(trials: Int = 20, completion: @escaping (Bool) -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-usage-timing-\(UUID())")
    var pending: [UsageFetchRequest] = []
    let usage = UsageLimitsModel(fetchers: [.codex: { pending.append($0) }, .claude: { pending.append($0) }],
                                 scheduleTimer: { _, _ in {} }, observeWake: { _ in {} })
    let model = AppModel(repository: StateRepository(url: directory.appendingPathComponent("state.json")),
                         catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] }, usage: usage)
    let controller = PanelController(model: model)
    controller.currentPID = { nil }; controller.restorePID = { _ in }; controller.dispatchURL = { _ in true }
    // The self-test is not the active app, so the harness can take key status at any moment;
    // without the delegate a lost key window does not dismiss the panel mid-trial.
    controller.panel.delegate = nil
    UsageDisplayMarker.panelVisible = { controller.panel.isVisible }
    func answerAll() {
        let instant = Date()
        for request in pending {
            request.emit(.finished(.success(UsageReading(windows: [UsageWindow(id: "w", label: "Weekly limit", usedPercent: 30,
                resetsAt: instant.addingTimeInterval(86_400))], checkedAt: instant, owner: UsageOwner(user: .unknown)))))
        }
        pending = []
    }
    var direct: [Double] = [], inPanel: [Double] = [], misses = 0
    var phase = 0, index = 0, started: TimeInterval = 0, waiting = false, generation = 0
    func finish() {
        UsageDisplayMarker.observer = nil
        controller.dismiss(.cancel)
        try? FileManager.default.removeItem(at: directory)
        func summary(_ samples: [Double]) -> String {
            let sorted = samples.sorted()
            return String(format: "median %.1f ms, worst %.1f ms", sorted[sorted.count / 2], sorted.last ?? 0)
        }
        let complete = direct.count == trials && inPanel.count == trials
        if complete {
            print("Usage Limits, warm and fixture-based, \(trials) trials each, trigger to the first Core Animation commit carrying Usage content (not a compositor frame): "
                  + "direct opening (menu item / Option-click path) \(summary(direct)); ⌘U posted to a settled compass \(summary(inPanel)).")
        } else {
            print("FAIL: usage timing trials reached displayed content \(direct.count)+\(inPanel.count) of \(trials * 2) times (\(misses) misses)")
        }
        completion(complete)
    }
    func step() {
        // One warm-up opening per phase is not counted.
        if index > trials { phase += 1; index = 0 }
        if phase > 1 { finish(); return }
        if phase == 0 {
            // From a hidden panel last showing the compass, as after an ordinary opening.
            controller.present(orderFront: false, assessOnOpen: false); controller.dismiss(.cancel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                started = ProcessInfo.processInfo.systemUptime; waiting = true
                controller.presentUsage()
                arm()
            }
        } else {
            // ⌘U on a compass whose own opening work has finished.
            controller.present(assessOnOpen: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: controller.panel.windowNumber, context: nil, characters: "u",
                                             charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32)!
                started = ProcessInfo.processInfo.systemUptime; waiting = true
                NSApp.postEvent(event, atStart: false)
                arm()
            }
        }
    }
    func arm() {
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard waiting, generation == current else { return }
            waiting = false; misses += 1; next()
        }
    }
    func next() {
        answerAll(); controller.dismiss(.cancel); index += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { step() }
    }
    UsageDisplayMarker.observer = { event in
        guard event == "usage.content.displayed", waiting else { return }
        waiting = false
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if index > 0 { if phase == 0 { direct.append(elapsed) } else { inPanel.append(elapsed) } }
        next()
    }
    // Warm: readings already in memory, as on every opening after the first.
    controller.presentUsage(orderFront: false); answerAll(); controller.dismiss(.cancel)
    DispatchQueue.main.async { step() }
}
