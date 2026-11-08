import Foundation

/// Main quick-switch choices are recent sessions, not a prediction of unfinished work.
/// Full catalog search is deliberately separate; an empty history is not backfilled
/// with sessions that merely have fresh metadata, matching words, or old task text.
public struct NavigationCompass {
    public enum Reason: String, Equatable { case selected, visited, created, pinned }
    public struct Entry: Equatable {
        public let destination: Destination
        public let interaction: ConversationTimestamp?
        public let reason: Reason
    }
    public let entries: [Entry]
    public var ordered: [Destination] { entries.map(\.destination) }
    public let currentKey: ConversationKey?
    private let recents: RecentSessionSnapshot

    /// `currentKey` must be an independently established current selection, never
    /// inferred from a background update or a model's attention classification.
    public init(state: SavedState, catalog: CatalogCache, context: ContextMemory = ContextMemory(),
                currentKey: ConversationKey? = nil, now: Date, uptime: TimeInterval) {
        self.currentKey = currentKey
        recents = RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: now, uptime: uptime)
        let excluded = Set(catalog.effectivePolicy.excludedConversationIDs)
        func permitted(_ item: Destination) -> Bool {
            !excluded.contains(item.conversationKey) &&
                !(item.provider == .codex && catalog.hiddenIDs.contains(item.threadID))
        }
        var seen = Set<ConversationKey>()
        let visited = recents.entries.filter { permitted($0.destination) }.map {
            Entry(destination: $0.destination, interaction: $0.interaction,
                  reason: $0.interaction.kind == .creation ? .created : ($0.interaction.kind == .visit ? .visited : .selected))
        }
        // Preserve exact MRU ordering among alternatives. Current remains reachable
        // after them, without consuming the first quick-return slot.
        let alternatives = visited.filter { $0.destination.conversationKey != currentKey }
        let current = visited.filter { $0.destination.conversationKey == currentKey }
        var result = (alternatives + current).filter { seen.insert($0.destination.conversationKey).inserted }
        // Pins are explicit intent, not inferred relevance. They fill only after
        // recorded interactions, in the user's persisted order.
        result += state.destinations.filter {
            $0.pinned && permitted($0) && seen.insert($0.conversationKey).inserted
        }.map { Entry(destination: $0, interaction: nil, reason: .pinned) }
        entries = result
    }

    public func visibleEntries(now: Date, uptime: TimeInterval, limit: Int = 5) -> [Entry] {
        guard limit > 0 else { return [] }
        // Fail closed on stale/clock-rewound history; pins remain explicit choices.
        let eligible = recents.isFresh(now: now, uptime: uptime) ? entries : entries.filter { $0.reason == .pinned }
        return Array(eligible.prefix(limit))
    }
}
