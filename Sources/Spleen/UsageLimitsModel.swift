import AppKit
import SpleenCore

typealias UsageFetch = (UsageFetchRequest) -> Void

/// Codex and Claude subscription limits for the Usage Limits view. Main thread only.
///
/// Nothing runs while the view is closed: no timer, no wake observer, no helper. Each opening
/// refreshes both providers independently; readings stay in memory only.
final class UsageLimitsModel: ObservableObject {
    struct ProviderState: Equatable {
        var reading: UsageReading?
        /// The latest identity the client reported; `unknown` never replaces a known one.
        var identity: UsageIdentity = .unknown
        var inFlight = false
        var requestID = 0
        var attemptStartedAt: Date?
        var lastAttemptAt: Date?
        var lastFailure: UsageFailure?
        var retryAfter: Date?
    }
    enum Status: Equatable {
        case loading
        case unavailable(UsageFailure, triedAt: Date)
        case checking(lastKnown: Date)
        case checked(Date)
        case lastKnown(Date, UsageFailure)
    }

    static let providers: [ContextProvider] = [.codex, .claude]
    static let usagePages: [ContextProvider: URL] = [.codex: URL(string: "https://chatgpt.com/codex/settings/usage")!,
                                                     .claude: URL(string: "https://claude.ai/settings/usage")!]

    @Published private(set) var codex = ProviderState()
    @Published private(set) var claude = ProviderState()
    /// The instant expiry is judged against. It moves on open, arrival, the reset timer and wake.
    @Published private(set) var now: Date
    private(set) var isOpen = false
    private(set) var openingID = 0
    private(set) var fetchCounts: [ContextProvider: Int] = [.codex: 0, .claude: 0]
    private(set) var timerTarget: Date?
    /// When the current opening began; a row whose reading is newer is a fresh row.
    private(set) var openedAt: Date?
    /// Spoken when a provider's answer arrives; set by the panel only while VoiceOver is on.
    var announce: ((String) -> Void)?

    private let clock: () -> Date
    private let fetchers: [ContextProvider: UsageFetch]
    private let scheduleTimer: (Date, @escaping () -> Void) -> () -> Void
    private let observeWake: (@escaping () -> Void) -> () -> Void
    private let shutdown: () -> Void
    private var cancelTimer: (() -> Void)?
    private var cancelWake: (() -> Void)?
    private var cancellations: [ContextProvider: HelperCancellation] = [:]

    init(clock: @escaping () -> Date = Date.init,
         fetchers: [ContextProvider: UsageFetch],
         scheduleTimer: @escaping (Date, @escaping () -> Void) -> () -> Void = UsageLimitsModel.mainTimer,
         observeWake: @escaping (@escaping () -> Void) -> () -> Void = UsageLimitsModel.wakeObserver,
         shutdown: @escaping () -> Void = {}) {
        self.clock = clock; self.fetchers = fetchers; self.scheduleTimer = scheduleTimer
        self.observeWake = observeWake; self.shutdown = shutdown
        now = clock()
    }

    func state(_ provider: ContextProvider) -> ProviderState { provider == .codex ? codex : claude }
    private func update(_ provider: ContextProvider, _ change: (inout ProviderState) -> Void) {
        var value = state(provider)
        change(&value)
        guard value != state(provider) else { return }
        if provider == .codex { codex = value } else { claude = value }
    }

    var hasTimer: Bool { cancelTimer != nil }
    var hasWakeObserver: Bool { cancelWake != nil }
    var hasOutstandingWork: Bool { !cancellations.isEmpty }
    var canRefresh: Bool { isOpen && Self.providers.contains { refreshable($0) } }

    func status(_ provider: ContextProvider) -> Status {
        let value = state(provider)
        if let reading = value.reading {
            if value.inFlight { return .checking(lastKnown: reading.checkedAt) }
            if let failure = value.lastFailure { return .lastKnown(reading.checkedAt, failure) }
            return .checked(reading.checkedAt)
        }
        if !value.inFlight, let failure = value.lastFailure, let tried = value.lastAttemptAt {
            return .unavailable(failure, triedAt: tried)
        }
        return .loading
    }

    /// Paints from memory at once; both providers refresh independently off the main thread.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        openingID += 1
        now = clock()
        openedAt = now
        cancelWake = observeWake { [weak self] in self?.reevaluate() }
        for provider in Self.providers { refresh(provider) }
        armTimer()
    }

    private func refreshable(_ provider: ContextProvider) -> Bool {
        let value = state(provider)
        return !value.inFlight && !(value.retryAfter.map { clock() < $0 } ?? false)
    }

    /// Coalesced: a no-op while that provider is in flight or backing off (manual refresh too).
    func refresh(_ provider: ContextProvider) {
        guard isOpen, refreshable(provider), let fetch = fetchers[provider] else { return }
        let started = clock()
        update(provider) { $0.requestID += 1; $0.inFlight = true; $0.attemptStartedAt = started }
        let value = state(provider), opening = openingID, request = value.requestID
        let token = HelperCancellation()
        cancellations[provider] = token
        fetchCounts[provider, default: 0] += 1
        fetch(UsageFetchRequest(cancellation: token, cachedOwner: value.reading?.owner) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event, from: provider, opening: opening, request: request) }
        })
    }

    func refreshAll() { for provider in Self.providers { refresh(provider) } }

    /// Previews only: replace a provider's state with invented values.
    func install(_ value: ProviderState, for provider: ContextProvider) {
        if provider == .codex { codex = value } else { claude = value }
    }

    /// Only the current request of the current opening is applied; late answers are ignored.
    private func receive(_ event: UsageEvent, from provider: ContextProvider, opening: Int, request: Int) {
        guard isOpen, opening == openingID, state(provider).requestID == request, state(provider).inFlight else { return }
        switch event {
        case .identity(let observed):
            apply(observed, to: provider)
        case .finished(let result):
            cancellations[provider] = nil
            let attempted = state(provider).attemptStartedAt ?? clock()
            update(provider) { value in
                value.inFlight = false
                value.lastAttemptAt = attempted
                switch result {
                case .success(var reading):
                    reading.checkedAt = attempted
                    value.reading = reading
                    value.lastFailure = nil; value.retryAfter = nil
                    if case .known = reading.owner.user { value.identity = reading.owner.user }
                case .failure(let problem):
                    // A failed refresh keeps the previous reading and its original timestamp.
                    value.lastFailure = problem.failure == .cancelled ? value.lastFailure : problem.failure
                    value.retryAfter = problem.retryAfter
                    if problem.failure == .signedOut { value.reading = nil; value.identity = .signedOut }
                }
            }
            now = clock()
            armTimer()
            if case .success = result { announce?("\(provider.displayName) usage limits updated") }
            else { announce?("\(provider.displayName) usage limits unavailable") }
        }
    }

    /// A confirmed change or sign-out drops that provider's cache at once, even if its usage
    /// read then fails. `unknown` changes nothing.
    private func apply(_ observed: UsageIdentity, to provider: ContextProvider) {
        guard observed != .unknown else { return }
        update(provider) { value in
            if let reading = value.reading, UsageIdentityRules.confirmsChange(cached: reading.owner.user, observed: observed) {
                value.reading = nil
            }
            value.identity = observed
        }
    }

    /// Cancels outstanding work and forgets the opening. Readings stay in memory; nothing is written.
    func close() {
        guard isOpen || cancelTimer != nil || cancelWake != nil || !cancellations.isEmpty else { return }
        isOpen = false
        openingID += 1
        for token in cancellations.values { token.cancel() }
        cancellations = [:]
        for provider in Self.providers { update(provider) { $0.inFlight = false } }
        cancelTimer?(); cancelTimer = nil; timerTarget = nil
        cancelWake?(); cancelWake = nil
    }

    /// Quit: cancel and reap every helper within the helpers' own bound.
    func terminate() { close(); shutdown() }

    /// The countdown, expiry and wake update the display only; they never start a read.
    /// One one-shot timer, armed only while open, targets the next instant at which any
    /// shown "in …" text changes (whole minutes counted back from each reset, the reset
    /// itself included). With no future reset nothing is scheduled.
    private func armTimer() {
        cancelTimer?(); cancelTimer = nil; timerTarget = nil
        guard isOpen else { return }
        let instant = clock()
        let next = Self.providers.compactMap { state($0).reading }.flatMap(\.windows).compactMap(\.resetsAt)
            .compactMap { UsageTimeFormat.nextChange(for: $0, after: instant) }.min()
        guard let next else { return }
        timerTarget = next
        cancelTimer = scheduleTimer(next) { [weak self] in self?.reevaluate() }
    }

    private func reevaluate() {
        guard isOpen else { return }
        now = clock()
        armTimer()
    }

    static func mainTimer(_ date: Date, _ fire: @escaping () -> Void) -> () -> Void {
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in fire() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    static func wakeObserver(_ handler: @escaping () -> Void) -> () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in handler() }
        return { center.removeObserver(token) }
    }
}

extension UsageLimitsModel {
    /// The installed clients, each on its own lane: one live helper and one pending launch per provider.
    static func live() -> UsageLimitsModel {
        let codexLane = HelperLane(label: "spleen.usage.codex"), claudeLane = HelperLane(label: "spleen.usage.claude")
        let gate = ClaudeUsageGate()
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UsageLimitsModel(fetchers: [
            .codex: { request in
                CodexUsage.fetch(executable: { installedCodexCatalogClient().executable }, workingDirectory: neutralHelperDirectory,
                                 environment: environment, lane: codexLane, request: request)
            },
            .claude: { request in
                ClaudeUsage.fetch(executable: { ClaudeUsage.resolveExecutable(home: home, path: environment["PATH"]) },
                                  workingDirectory: neutralHelperDirectory, environment: environment,
                                  lane: claudeLane, gate: gate, request: request)
            }
        ], shutdown: {
            codexLane.cancelAll(); claudeLane.cancelAll()
            codexLane.waitUntilIdle(timeout: 1.5); claudeLane.waitUntilIdle(timeout: 1.5)
        })
    }

    /// An empty directory Spleen owns under its caches folder, so no client reads project files.
    static func neutralHelperDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Spleen", isDirectory: true)
            .appendingPathComponent("usage-helper", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                      attributes: [.posixPermissions: 0o700])) != nil {
            return directory
        }
        return FileManager.default.temporaryDirectory
    }
}
