import Foundation

public struct RecentSession: Identifiable, Equatable {
    public var id: UUID { destination.id }
    public let destination: Destination
    public let interaction: ConversationTimestamp
}

/// Chronological session creation, user selections and observed visits, independent of relevance,
/// pins, reply timestamps, and background activity. Prepared off the opening path.
public struct RecentSessionSnapshot {
    public let entries: [RecentSession]
    private let builtAt: Date
    private let builtUptime: TimeInterval
    private let expiresAt: Date
    private let expiresUptime: TimeInterval

    public init(state: SavedState, catalog: CatalogCache, context: ContextMemory = ContextMemory(),
                now: Date, uptime: TimeInterval) {
        builtAt = now; builtUptime = uptime
        let visits = ClaudeDesktopRecents(context, excluding: catalog.effectivePolicy.excludedConversationIDs, now: now)
        var times: [ConversationKey: ConversationTimestamp] = [:]
        func remember(_ key: ConversationKey, _ timestamp: ConversationTimestamp) {
            guard timestamp.date <= now, now.timeIntervalSince(timestamp.date) < ContextMemory.retention,
                  timestamp.date > (times[key]?.date ?? .distantPast) ||
                    (timestamp.date == times[key]?.date && times[key]?.kind == .creation && timestamp.kind != .creation) else { return }
            times[key] = timestamp
        }
        if state.rememberRecents {
            // Creation is a separate, provider-supplied fact. Updates/replies do
            // not move an unvisited session up the list or establish a visit.
            for item in catalog.entries where catalog.includes(item) && !catalog.hiddenIDs.contains(item.id) {
                if let date = item.createdAt, date <= item.updatedAt,
                   date > (state.recentHistoryClearedAt ?? .distantPast) {
                    remember(item.destination.conversationKey, ConversationTimestamp(kind: .creation, date: date))
                }
            }
            for item in state.destinations {
                if let date = item.lastOpenedAt { remember(item.conversationKey, ConversationTimestamp(kind: .selection, date: date)) }
            }
            for hint in context.recentInteractions(at: now) + context.observedSelections(at: now) {
                if hint.evidence == .observedSelection {
                    remember(hint.key, ConversationTimestamp(kind: .visit, date: hint.observedAt))
                } else if hint.evidence == .spleenInteraction && hint.source == "spleen" {
                    remember(hint.key, ConversationTimestamp(kind: .selection, date: hint.observedAt))
                }
            }
            for visit in visits.entries {
                remember(visit.destination.conversationKey, ConversationTimestamp(kind: .visit, date: visit.observedAt))
            }
        }
        let excluded = Set(catalog.effectivePolicy.excludedConversationIDs)
        // Exact foreground routes can precede the catalog refresh. Keep observed
        // local Codex sessions available without pretending background catalog
        // updates were navigation. Explicitly hidden sessions stay hidden.
        let codexVisits: [Destination] = state.rememberRecents ? context.observedSelections(at: now).compactMap { hint in
            guard hint.key.provider == .codex, hint.source == "codex-desktop-accessibility",
                  !excluded.contains(hint.key), !catalog.hiddenIDs.contains(hint.key.id), let id = UUID(uuidString: hint.key.id) else { return nil }
            return Destination(id: id, title: hint.topic?.isEmpty == false ? hint.topic! : "Codex · " + hint.key.id.suffix(8), threadID: hint.key.id)
        } : []
        let candidates = catalog.merged(with: state).destinations + visits.entries.map(\.destination) + codexVisits
        var seen = Set<ConversationKey>()
        entries = Array(candidates.compactMap { item -> RecentSession? in
            guard seen.insert(item.conversationKey).inserted, let timestamp = times[item.conversationKey] else { return nil }
            return RecentSession(destination: item, interaction: timestamp)
        }.sorted {
            if $0.interaction.date != $1.interaction.date { return $0.interaction.date > $1.interaction.date }
            let a = $0.destination.conversationKey, b = $1.destination.conversationKey
            return a.provider == b.provider ? a.id < b.id : a.provider.rawValue < b.provider.rawValue
        }.prefix(ContextMemory.maximumEvents))
        expiresAt = entries.map { $0.interaction.date.addingTimeInterval(ContextMemory.retention) }.min() ?? .distantFuture
        expiresUptime = uptime + expiresAt.timeIntervalSince(now)
    }

    /// False once any entry has expired, so callers know to rebuild.
    public func isFresh(now: Date, uptime: TimeInterval) -> Bool {
        now >= builtAt && uptime >= builtUptime && now < expiresAt && uptime < expiresUptime
    }
    public func clockMovedBackwards(now: Date, uptime: TimeInterval) -> Bool {
        now < builtAt || uptime < builtUptime
    }
    /// Entries still within retention. Each ages on its own, so the oldest expiring
    /// does not empty the list; a clock moved backwards still fails closed.
    public func visibleEntries(now: Date, uptime: TimeInterval) -> [RecentSession] {
        guard !clockMovedBackwards(now: now, uptime: uptime) else { return [] }
        if isFresh(now: now, uptime: uptime) { return entries }
        // Age by whichever clock moved further: wall time covers sleep, monotonic
        // time covers a wall clock adjusted after the build.
        let elapsed = max(now.timeIntervalSince(builtAt), uptime - builtUptime)
        return entries.filter { builtAt.timeIntervalSince($0.interaction.date) + elapsed < ContextMemory.retention }
    }
}
