import Foundation

/// A serial worker with one replaceable pending job. Bursts retain only the newest waiting build.
/// The supplied validity check lets a running build skip later expensive stages once superseded.
public final class LatestSnapshotScheduler {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "spleen.relevance", qos: .utility)
    private var generation = 0
    private var running = false
    private var pending: (generation: Int, work: (() -> Bool) -> Void)?
    public init() {}
    public func submit(_ work: @escaping (() -> Bool) -> Void) {
        lock.lock()
        generation += 1
        pending = (generation, work)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func isCurrent(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == value
    }
    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else { running = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            next.work { self.isCurrent(next.generation) }
        }
    }
}

/// Rank-relevant interaction state, excluding the bounded lifecycle/audit event log.
public struct ContextRelevanceSignature: Equatable {
    private let current: ContextHint?
    private let previous: ContextHint?
    private let transitions: [ContextTransition]
    private let observed: ContextHint?
    private let claudeRecents: ClaudeDesktopRecents
    private let interactions: [ContextHint]
    private let selections: [ContextHint]
    public init(_ memory: ContextMemory, now: Date) {
        current = memory.currentHint(at: now)
        previous = memory.previousDistinct(at: now)
        transitions = memory.transitions(at: now)
        observed = memory.latestObservedSelection(at: now)
        claudeRecents = ClaudeDesktopRecents(memory, now: now)
        interactions = memory.recentInteractions(at: now)
        selections = memory.observedSelections(at: now)
    }
    public func hasSameInteractions(as other: Self) -> Bool {
        current == other.current && previous == other.previous && transitions == other.transitions && claudeRecents == other.claudeRecents && interactions == other.interactions && selections == other.selections
    }
}

/// Both indexes are built off the opening path. Selection is a handful of clock comparisons.
public struct PreparedContext {
    public let recentSessions: RecentSessionSnapshot
    public let contextual: RelevanceSnapshot
    public let fallback: RelevanceSnapshot
    private let expiredRecentsFallback: RelevanceSnapshot
    private let boundaries: [(date: Date, uptime: TimeInterval, snapshot: RelevanceSnapshot)]
    private let builtAt: Date
    private let builtUptime: TimeInterval
    private let expiresAt: Date?
    private let expiresUptime: TimeInterval?
    private let recentsExpireAt: Date?
    private let recentsExpireUptime: TimeInterval?
    public static let empty = PreparedContext(state: SavedState(), catalog: CatalogCache(),
                                              now: Date(), uptime: 0)
    public init(state: SavedState, catalog: CatalogCache, insights: [ThreadInsight] = [],
                context: ContextMemory = ContextMemory(), now: Date, uptime: TimeInterval, attention: SessionAttention = SessionAttention()) {
        builtAt = now; builtUptime = uptime
        recentSessions = RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: now, uptime: uptime)
        let visits = ClaudeDesktopRecents(state.rememberRecents ? context : ContextMemory(recentsEnabled: false),
            excluding: catalog.effectivePolicy.excludedConversationIDs, now: now)
        recentsExpireAt = visits.expiresAt
        recentsExpireUptime = visits.expiresAt.map { uptime + max(0, $0.timeIntervalSince(now)) }
        contextual = RelevanceSnapshot(state: state, catalog: catalog, insights: insights, context: context, now: now, claudeRecents: visits, attention: attention)
        let hintExpiry = context.currentHint(at: now)?.observedAt.addingTimeInterval(ContextMemory.hintLifetime)
        let legacyExpiry = state.destinations.compactMap(\.lastOpenedAt).filter {
            $0 <= now && now.timeIntervalSince($0) < ContextMemory.hintLifetime
        }.max()?.addingTimeInterval(ContextMemory.hintLifetime)
        if state.rememberRecents, let expiry = hintExpiry ?? legacyExpiry {
            expiresAt = expiry; expiresUptime = uptime + max(0, expiry.timeIntervalSince(now))
            var neutral = state
            // Retain ordinary selection recency scores, but remove any inferred active topic/project.
            neutral.rememberRecents = false
            fallback = RelevanceSnapshot(state: neutral, catalog: catalog, insights: insights, now: expiry, claudeRecents: visits, attention: attention)
        } else { expiresAt = nil; expiresUptime = nil; fallback = contextual }
        let dates = state.rememberRecents ? Set(
            (context.events.filter { $0.kind == .spleenDispatch && $0.source == "spleen" }.map(\.observedAt) +
             visits.entries.map(\.observedAt) + state.destinations.compactMap(\.lastOpenedAt) +
             [context.currentHint(at: now)?.observedAt].compactMap { $0 })
                .map { $0.addingTimeInterval(ContextMemory.hintLifetime) }.filter { $0 > now }) : []
        let deadlines = dates.union((attention.liveExpirationDates + attention.recentActivityExpirationDates).filter { $0 > now })
        boundaries = deadlines.sorted().map { date in
            (date, uptime + date.timeIntervalSince(now), RelevanceSnapshot(state: state, catalog: catalog,
                insights: insights, context: context, now: date, claudeRecents: visits, attention: attention))
        }
        var neutral = state; neutral.rememberRecents = false
        expiredRecentsFallback = visits.entries.isEmpty ? fallback : RelevanceSnapshot(state: neutral, catalog: catalog, insights: insights, now: now)
    }
    /// A prebuilt fail-closed value covers sleep/clock changes without filtering on open.
    /// An off-path rebuild can then restore the other visits that have not yet expired.
    public func recentsExpired(now: Date, uptime: TimeInterval) -> Bool {
        guard let recentsExpireAt, let recentsExpireUptime else { return false }
        return now < builtAt || uptime < builtUptime || now > recentsExpireAt || uptime > recentsExpireUptime
    }
    public func isFresh(now: Date, uptime: TimeInterval) -> Bool {
        guard !recentsExpired(now: now, uptime: uptime) else { return false }
        if let first = boundaries.first, now >= first.date || uptime >= first.uptime { return false }
        guard let expiresAt, let expiresUptime else { return now >= builtAt && uptime >= builtUptime }
        // Wall time covers sleep; monotonic time prevents a backwards wall adjustment extending evidence.
        return now >= builtAt && uptime >= builtUptime && now < expiresAt && uptime < expiresUptime
    }
    public func snapshot(now: Date, uptime: TimeInterval) -> RelevanceSnapshot {
        if recentsExpired(now: now, uptime: uptime) { return expiredRecentsFallback }
        guard now >= builtAt, uptime >= builtUptime else { return fallback }
        var lower = 0, upper = boundaries.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if now >= boundaries[mid].date || uptime >= boundaries[mid].uptime { lower = mid + 1 }
            else { upper = mid }
        }
        if lower > 0 { return boundaries[lower - 1].snapshot }
        return isFresh(now: now, uptime: uptime) ? contextual : fallback
    }
}

public enum CatalogPersistenceError: Error { case corruptExisting }

/// Used only on the app's serial cache writer. Validate a staged value and preserve corrupt stores.
public enum CatalogPersistence {
    public static func write(_ value: CatalogCache, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try value.save(to: staging)
        _ = try CatalogCache.load(from: staging)
        if FileManager.default.fileExists(atPath: url.path) {
            do { _ = try CatalogCache.load(from: url) }
            catch { throw CatalogPersistenceError.corruptExisting }
        }
        try Data(contentsOf: staging).write(to: url, options: .atomic)
    }
}
