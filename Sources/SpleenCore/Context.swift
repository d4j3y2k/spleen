import Foundation

public enum ContextProvider: String, Codable, CaseIterable, Hashable {
    case codex, claude
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}

/// Provider is part of identity: equal opaque IDs in different apps are different chats.
public struct ConversationKey: Codable, Hashable {
    public var provider: ContextProvider
    public var id: String
    public init(provider: ContextProvider, id: String) { self.provider = provider; self.id = id }
}

public enum ContextEventKind: String, Codable {
    case selectedConversation, spleenDispatch, userPromptSubmitted
    case sessionStarted, turnCompleted, threadUpdated
}

public enum ContextEvidence: String, Codable {
    case observedSelection, spleenInteraction, inferredHumanActivity, lifecycle, background
}

/// Metadata only. `source` identifies the adapter, never a transcript or prompt.
public struct ContextEvent: Codable, Equatable {
    public var key: ConversationKey
    public var project: String?
    /// An approved short title/topic, never message contents or an accessibility tree.
    public var topic: String? { didSet { topic = topic.map { String($0.prefix(280)) } } }
    public var kind: ContextEventKind
    public var observedAt: Date
    public var source: String
    public var evidence: ContextEvidence
    public init(key: ConversationKey, project: String? = nil, topic: String? = nil, kind: ContextEventKind,
                observedAt: Date = Date(), source: String, evidence: ContextEvidence) {
        self.key = key; self.project = project; self.topic = topic.map { String($0.prefix(280)) }; self.kind = kind
        self.observedAt = observedAt; self.source = source; self.evidence = evidence
    }
    public var contributesInteraction: Bool {
        switch (kind, evidence) {
        case (.selectedConversation, .observedSelection), (.spleenDispatch, .observedSelection),
             (.spleenDispatch, .spleenInteraction),
             (.userPromptSubmitted, .inferredHumanActivity): return true
        default: return false
        }
    }
}

public struct ContextHint: Codable, Equatable {
    public let key: ConversationKey
    public let project: String?
    public let topic: String?
    public let observedAt: Date
    public let evidence: ContextEvidence
    public let source: String
    fileprivate init(_ event: ContextEvent) {
        key = event.key; project = event.project; topic = event.topic; observedAt = event.observedAt
        evidence = event.evidence; source = event.source
    }
}

public struct ContextTransition: Equatable {
    public let from: ConversationKey
    public let to: ConversationKey
    public let observedAt: Date
    public let evidence: ContextEvidence
}

public enum ContextStoreError: Error { case invalidStore }

/// An observer's immediate report that a conversation came to the front, made before
/// its visit dwell elapses. Placement only: never persisted, never an interaction,
/// visit or transition.
public struct ForegroundHint: Equatable {
    public let key: ConversationKey
    public let at: Date
    public init(key: ConversationKey, at: Date) { self.key = key; self.at = at }
}

/// Pure, bounded local state. No app inspection, hook installation, or network work.
public struct ContextMemory: Codable {
    public static let schemaVersion = 1
    public static let maximumEvents = 64
    public static let retention: TimeInterval = 30 * 24 * 60 * 60
    public static let hintLifetime: TimeInterval = 30 * 60
    public private(set) var recentsEnabled: Bool
    /// Transient. Not encoded; set by the app on the copy it hands to a snapshot build.
    public var foreground: ForegroundHint?

    /// Where the user is now. A fresh foreground report that is newer than every
    /// recorded interaction wins over the recorded conversation, which then becomes
    /// the quick-return target. Once its own visit, or any later interaction, is
    /// recorded, the recorded state wins again.
    public static func resolveCurrent(recorded: ConversationKey?, recordedAt: Date?, previous: ConversationKey?,
                                      foreground: ForegroundHint?, at now: Date) -> (current: ConversationKey?, previous: ConversationKey?) {
        guard let foreground, foreground.at <= now, now.timeIntervalSince(foreground.at) < hintLifetime,
              foreground.at >= (recordedAt ?? .distantPast), foreground.key != recorded else { return (recorded, previous) }
        return (foreground.key, recorded ?? previous)
    }
    public private(set) var events: [ContextEvent] = []
    // Consecutive repetitions collapse; revisiting A after B remains a real transition.
    private var interactions: [ContextHint] = []
    // Navigation identity survives a busy lifecycle audit and same-session dispatch.
    private var selections: [ContextHint] = []

    public init(recentsEnabled: Bool = true) { self.recentsEnabled = recentsEnabled }

    public mutating func setRecentsEnabled(_ enabled: Bool) {
        recentsEnabled = enabled
        if !enabled { clear() }
    }
    public mutating func clear() { events.removeAll(); interactions.removeAll(); selections.removeAll() }

    /// Returns false for disabled, duplicate, invalid, expired, or future events.
    /// Older arriving observations are retained for provenance but cannot rewind attention.
    @discardableResult
    public mutating func record(_ event: ContextEvent, now: Date = Date()) -> Bool {
        prune(now: now)
        guard recentsEnabled, Self.valid(event), event.observedAt <= now,
              now.timeIntervalSince(event.observedAt) <= Self.retention,
              !events.contains(event) else { return false }
        if event.kind == .selectedConversation && event.evidence == .observedSelection {
            if let old = selections.first(where: { $0.key == event.key }), old.observedAt > event.observedAt {} else {
                var observed = event
                if observed.topic?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    observed.topic = selections.first(where: { $0.key == event.key })?.topic
                }
                selections.removeAll { $0.key == event.key }
                selections.append(ContextHint(observed))
                selections.sort { $0.observedAt < $1.observedAt }
                if selections.count > Self.maximumEvents { selections.removeFirst(selections.count - Self.maximumEvents) }
            }
        }
        events.append(event)
        events.sort { $0.observedAt < $1.observedAt }
        if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
        guard event.contributesInteraction else { return true }
        if let last = interactions.last {
            guard event.observedAt >= last.observedAt else { return true }
            // A same-timestamp different key has no trustworthy ordering.
            guard event.observedAt != last.observedAt || event.key == last.key else { return true }
        }
        if interactions.last?.key == event.key { interactions.removeLast() }
        interactions.append(ContextHint(event))
        if interactions.count > Self.maximumEvents { interactions.removeFirst(interactions.count - Self.maximumEvents) }
        return true
    }

    public mutating func prune(now: Date = Date()) {
        if !recentsEnabled { clear(); return }
        let oldest = now.addingTimeInterval(-Self.retention)
        events.removeAll { $0.observedAt < oldest || $0.observedAt > now }
        interactions.removeAll { $0.observedAt < oldest || $0.observedAt > now }
        selections.removeAll { $0.observedAt < oldest || $0.observedAt > now }
    }

    /// A fresh hint is evidence of interaction, not a claim that the app is still foreground.
    public func currentHint(at now: Date = Date()) -> ContextHint? {
        guard recentsEnabled, let last = retainedInteractions(at: now).last,
              now.timeIntervalSince(last.observedAt) < Self.hintLifetime else { return nil }
        return last
    }

    /// Only an adapter that actually observed an app selection can supply this.
    /// Dispatch success and hook activity alone never establish a viewed conversation.
    public func latestObservedSelection(at now: Date = Date()) -> ContextHint? {
        guard recentsEnabled else { return nil }
        return selections.last(where: {
            $0.observedAt <= now && now.timeIntervalSince($0.observedAt) < Self.hintLifetime
        })
    }

    /// Stable previous *distinct interaction*, available even when the current hint expires.
    public func previousDistinct(at now: Date = Date()) -> ContextHint? {
        let values = retainedInteractions(at: now)
        return values.count >= 2 ? values[values.count - 2] : nil
    }

    public func transitions(at now: Date = Date()) -> [ContextTransition] {
        let values = retainedInteractions(at: now)
        return zip(values, values.dropFirst()).map {
            ContextTransition(from: $0.key, to: $1.key, observedAt: $1.observedAt, evidence: $1.evidence)
        }
    }

    public func observedSelections(at now: Date = Date()) -> [ContextHint] {
        guard recentsEnabled else { return [] }
        return selections.filter { $0.observedAt <= now && now.timeIntervalSince($0.observedAt) <= Self.retention }
    }

    public func recentInteractions(at now: Date = Date()) -> [ContextHint] {
        guard recentsEnabled else { return [] }
        return interactions.filter { $0.observedAt <= now && now.timeIntervalSince($0.observedAt) <= Self.retention }
    }
    private func retainedInteractions(at now: Date) -> [ContextHint] { recentInteractions(at: now) }
    private static func valid(_ event: ContextEvent) -> Bool {
        !event.key.id.isEmpty && event.key.id.utf8.count <= 512 &&
        !event.source.isEmpty && event.source.utf8.count <= 256 &&
        (event.project?.utf8.count ?? 0) <= 4096 && (event.topic?.count ?? 0) <= 280 &&
        event.observedAt.timeIntervalSince1970.isFinite
    }

    private enum CodingKeys: String, CodingKey { case version, recentsEnabled, events, interactions, selections }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        guard try box.decode(Int.self, forKey: .version) == Self.schemaVersion else { throw ContextStoreError.invalidStore }
        recentsEnabled = try box.decode(Bool.self, forKey: .recentsEnabled)
        events = try box.decode([ContextEvent].self, forKey: .events)
        interactions = try box.decode([ContextHint].self, forKey: .interactions)
        selections = try box.decodeIfPresent([ContextHint].self, forKey: .selections) ?? []
        guard selections.count <= Self.maximumEvents, selections.allSatisfy({ hint in
            hint.evidence == .observedSelection && Self.valid(ContextEvent(key: hint.key, project: hint.project,
                topic: hint.topic, kind: .selectedConversation, observedAt: hint.observedAt,
                source: hint.source, evidence: hint.evidence))
        }) else { throw ContextStoreError.invalidStore }
        guard events.count <= Self.maximumEvents, interactions.count <= Self.maximumEvents,
              events.allSatisfy(Self.valid),
              interactions.allSatisfy({ hint in
                  (hint.topic?.count ?? 0) <= 280 &&
                  Self.valid(ContextEvent(key: hint.key, project: hint.project, topic: hint.topic, kind: .selectedConversation,
                      observedAt: hint.observedAt, source: hint.source, evidence: hint.evidence)) &&
                  (hint.evidence == .observedSelection || hint.evidence == .spleenInteraction || hint.evidence == .inferredHumanActivity)
              }),
              zip(interactions, interactions.dropFirst()).allSatisfy({ $0.observedAt < $1.observedAt && $0.key != $1.key })
        else { throw ContextStoreError.invalidStore }
        // Older stores can retain an observed visit only in interactions after
        // the audit log rolls over. Also repair stores already saved with an
        // incomplete selections array by the original migration.
        let observations = events.filter {
            $0.kind == .selectedConversation && $0.evidence == .observedSelection
        }.map(ContextHint.init) + interactions.filter { $0.evidence == .observedSelection } + selections
        var recovered: [ConversationKey: ContextHint] = [:]
        for hint in observations.sorted(by: { $0.observedAt < $1.observedAt }) {
            let title = hint.topic?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? hint.topic : recovered[hint.key]?.topic
            recovered[hint.key] = ContextHint(ContextEvent(key: hint.key, project: hint.project, topic: title,
                kind: .selectedConversation, observedAt: hint.observedAt, source: hint.source, evidence: hint.evidence))
        }
        selections = Array(recovered.values.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.key.provider == $1.key.provider ? $0.key.id < $1.key.id : $0.key.provider.rawValue < $1.key.provider.rawValue
        }.suffix(Self.maximumEvents))
        if !recentsEnabled { clear() }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(Self.schemaVersion, forKey: .version)
        try box.encode(recentsEnabled, forKey: .recentsEnabled)
        try box.encode(events, forKey: .events)
        try box.encode(interactions, forKey: .interactions)
        try box.encode(selections, forKey: .selections)
    }
}
