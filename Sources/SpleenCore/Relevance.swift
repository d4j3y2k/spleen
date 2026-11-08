import Foundation

/// Recognition excerpts plus an optional bounded, versioned recent-message window.
/// Neither historical text nor timestamps establish live runtime or unread state.
public struct ThreadInsight: Codable, Equatable {
    public let id: String
    public let folder: String
    public let updatedAt: Date
    public let topic: String
    public let decision: String
    public let nextStep: String
    public let timing: TurnTiming?
    public let window: SessionWindow?
    public init(id: String, folder: String, updatedAt: Date, topic: String, decision: String = "", nextStep: String = "", timing: TurnTiming? = nil, window: SessionWindow? = nil) {
        self.id = id; self.folder = folder; self.updatedAt = updatedAt
        self.topic = String(topic.prefix(280)); self.decision = String(decision.prefix(280)); self.nextStep = String(nextStep.prefix(280))
        self.timing = timing; self.window = window
    }
    public var text: String { [topic, decision, nextStep].joined(separator: " ") }
}

public struct InsightCache: Codable {
    public var version = 1
    public var entries: [ThreadInsight] = []
    public init() {}
    public mutating func retain(catalog: CatalogCache) {
        let allowed = Dictionary(uniqueKeysWithValues: catalog.entries.filter { catalog.includes($0) }.map { ($0.id, $0) })
        entries.removeAll { catalog.hiddenIDs.contains($0.id) || allowed[$0.id]?.folder != $0.folder || allowed[$0.id]?.updatedAt != $0.updatedAt }
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 16_000_000 else { throw SpleenError.invalidStore }
        let cache = try JSONDecoder().decode(Self.self, from: data)
        guard cache.version == 1, cache.entries.count <= 1000,
              Set(cache.entries.map(\.id)).count == cache.entries.count,
              cache.entries.allSatisfy({ $0.topic.count <= 280 && $0.decision.count <= 280 && $0.nextStep.count <= 280 && ($0.window?.messages.count ?? 0) <= 6 && ($0.window?.messages.allSatisfy { $0.text.unicodeScalars.count <= 2400 } ?? true) }) else { throw SpleenError.invalidStore }
        return cache
    }
}

public enum InsightDecoder {
    public static func validateMetadata(_ data: Data, entry: CatalogEntry, folders: [String]) throws {
        struct Thread: Decodable { let id: String; let cwd: String; let updatedAt: Double }
        struct Response: Decodable { let thread: Thread }
        let thread = try JSONDecoder().decode(Response.self, from: data).thread
        guard folders.contains(entry.folder), thread.id == entry.id, thread.cwd == entry.folder,
              thread.updatedAt == entry.updatedAt.timeIntervalSince1970 else { throw CatalogError.invalidScope }
    }
    /// The server returns newest items first. Ignore tools, reasoning, images and injected context blocks.
    public static func page(_ data: Data, entry: CatalogEntry) throws -> ThreadInsight {
        struct Content: Decodable { let type: String; let text: String? }
        struct Item: Decodable { let id: String?; let type: String; let text: String?; let content: [Content]?; let phase: String? }
        struct Row: Decodable {
            let id: String?
            let items: [Item]
            let status: String?
            let startedAt: Double?
            let completedAt: Double?
        }
        struct Page: Decodable { let data: [Row] }
        let page = try JSONDecoder().decode(Page.self, from: data)
        var user: [String] = [], agent: [String] = []
        func clean(_ text: String) -> String {
            // Exclude structured environment/instruction payloads and fenced code, preserving prose only.
            var inCode = false, inBlock = false
            return String(text.prefix(12_000)).components(separatedBy: .newlines).compactMap { line -> String? in
                let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("```") { inCode.toggle(); return nil }
                if line.hasPrefix("</") { inBlock = false; return nil }
                if line.hasPrefix("<") { inBlock = !line.contains("</"); return nil }
                guard !inCode, !inBlock, !line.isEmpty else { return nil }
                return line
            }.joined(separator: " ")
        }
        for item in page.data.prefix(3).flatMap(\.items).prefix(24) {
            if item.type == "userMessage" {
                let value = clean((item.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined(separator: " "))
                if !value.isEmpty { user.append(value) }
            } else if item.type == "agentMessage", item.phase != "commentary", let text = item.text {
                let value = clean(text); if !value.isEmpty { agent.append(value) }
            }
        }
        let sentences = agent.prefix(3).flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) }
        func excerpt(_ terms: [String]) -> String {
            String((sentences.first { sentence in terms.contains { TextIndex.normalize(sentence).contains($0) } } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        }
        let substantive = user.filter { TextIndex.terms($0).count >= 4 }
        let topicParts = substantive.prefix(2).map { String($0.prefix(100)) } + agent.prefix(1).map { String($0.prefix(80)) }
        let checkedAt = Date()
        func date(_ value: Double?) -> Date? {
            guard let value, value.isFinite, value > 0, value <= checkedAt.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        let recentTurns = Array(page.data.prefix(3))
        let timing = TurnTiming(lastStartedAt: recentTurns.compactMap { date($0.startedAt) }.max(),
            lastCompletedAt: recentTurns.compactMap { turn -> Date? in
                guard turn.status == "completed", let completed = date(turn.completedAt),
                      turn.startedAt == nil || (date(turn.startedAt).map { $0 <= completed } ?? false) else { return nil }
                return completed
            }.max(), checkedAt: checkedAt)
        var messages: [RecentMessage] = []
        var incomplete = false
        for (turnIndex, turn) in page.data.prefix(2).reversed().enumerated() {
            for (itemIndex, item) in turn.items.enumerated() {
                let role: RecentMessage.Role
                let raw: String
                if item.type == "userMessage" {
                    role = .user
                    raw = (item.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
                    if (item.content ?? []).contains(where: { $0.type != "text" }) { incomplete = true }
                } else if item.type == "agentMessage", item.phase != "commentary", let text = item.text {
                    role = .assistant; raw = text
                } else { continue }
                // Remove injected environment blocks only. Keep code and reply endings;
                // omissions/truncation must never masquerade as full coverage.
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<environment_context>") { continue }
                guard !raw.isEmpty else { continue }
                messages.append(RecentMessage(id: item.id ?? "\(turn.id ?? String(turnIndex)):\(itemIndex)", role: role, text: raw))
            }
        }
        let window = SessionWindow(key: ConversationKey(provider: .codex, id: entry.id), sourceUpdatedAt: entry.updatedAt,
            messages: messages, incomplete: incomplete || messages.isEmpty)
        return ThreadInsight(id: entry.id, folder: entry.folder, updatedAt: entry.updatedAt,
            topic: topicParts.isEmpty ? (user.first ?? "") : topicParts.joined(separator: " · "), decision: excerpt(["decided", "chose", "will use", "implemented", "changed"]),
            nextStep: excerpt(["next step", "remaining", "still need", "todo", "blocked", "follow up"]), timing: timing, window: window)
    }
}

public enum TextIndex {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static let stop = Set("the a an and or to of in on for with this that is are was be it we i you my our have has will can should from as at by about please use using into work chat thread need want let's get done now what how do does not but if then also just all when would could".split(separator: " ").map(String.init))
    public static func terms(_ text: String) -> Set<String> {
        Set(normalize(text).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) }.prefix(160))
    }
}

/// Recognition details from the same validated metadata and notes as the search index.
public struct ConversationPreview: Equatable {
    public let project: String?
    public let excerpt: String?
    public let timing: TurnTiming?
    public let lastVisitedAt: Date?
    public let lastSelectedAt: Date?
    public let observedReplyAt: Date?
    public init(project: String? = nil, excerpt: String? = nil, timing: TurnTiming? = nil,
                lastVisitedAt: Date? = nil, lastSelectedAt: Date? = nil, observedReplyAt: Date? = nil) {
        self.project = project
        let clean = excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.excerpt = clean?.isEmpty == false ? clean : nil
        self.timing = timing
        self.lastVisitedAt = lastVisitedAt; self.lastSelectedAt = lastSelectedAt
        self.observedReplyAt = observedReplyAt
    }
    public func timestamp(at now: Date) -> ConversationTimestamp? {
        replyTimestamp(at: now) ?? interactionTimestamp(at: now)
    }
    public func replyTimestamp(at now: Date) -> ConversationTimestamp? {
        if let completed = timing?.lastCompletedAt, completed <= now {
            return ConversationTimestamp(kind: .reply, date: completed)
        }
        if let observedReplyAt, observedReplyAt <= now {
            return ConversationTimestamp(kind: .reply, date: observedReplyAt, approximate: true)
        }
        return nil
    }
    public func interactionTimestamp(at now: Date) -> ConversationTimestamp? {
        let visited = lastVisitedAt.flatMap { $0 <= now ? $0 : nil }
        let selected = lastSelectedAt.flatMap { $0 <= now ? $0 : nil }
        if let visited, selected == nil || visited >= selected! {
            return ConversationTimestamp(kind: .visit, date: visited)
        }
        return selected.map { ConversationTimestamp(kind: .selection, date: $0) }
    }
}

/// Immutable value built off the presentation path. Search touches only normalized in-memory strings.
public struct RelevanceSnapshot: Equatable {
    // Favor returning to the previous distinct conversation without reserving
    // the center for it. These are ranking weights, never observation times.
    private static let previousConversationBonus = 24.0
    private static let previousRecencyAdvantage: TimeInterval = 10 * 60
    private struct Row: Equatable {
        let destination: Destination
        let title: String
        let corpus: String
        let terms: Set<String>
        let folder: String?
        let visitedAt: Date?
        let selectedAt: Date?
        let recordedSelectionAt: Date?
    }
    private let rows: [Row]
    public let currentKey: ConversationKey?
    public let previousKey: ConversationKey?
    public let ordered: [Destination]
    public let subtitles: [ConversationKey: String]
    public let previews: [ConversationKey: ConversationPreview]
    public static let empty = RelevanceSnapshot(state: SavedState(), catalog: CatalogCache())
    public init(state: SavedState, catalog: CatalogCache, insights: [ThreadInsight] = [], context: ContextMemory = ContextMemory(), now: Date = Date(), claudeRecents: ClaudeDesktopRecents? = nil, attention: SessionAttention = SessionAttention()) {
        let metadata = Dictionary(uniqueKeysWithValues: catalog.entries.filter { catalog.includes($0) }.map { ($0.id, $0) })
        let notes = Dictionary(uniqueKeysWithValues: insights.filter { metadata[$0.id]?.folder == $0.folder && metadata[$0.id]?.updatedAt == $0.updatedAt }.map { ($0.id, $0) })
        let visits = claudeRecents ?? ClaudeDesktopRecents(state.rememberRecents ? context : ContextMemory(recentsEnabled: false),
            excluding: catalog.effectivePolicy.excludedConversationIDs, now: now)
        let visited = Dictionary(uniqueKeysWithValues: visits.entries.map { ($0.destination.conversationKey, $0.observedAt) })
        // An accepted Spleen selection is useful recency, but is not an observed visit.
        // It cannot create a Claude candidate without a previously observed identity.
        var selected: [ConversationKey: Date] = [:]
        if state.rememberRecents {
            for event in context.events where event.kind == .spleenDispatch && event.source == "spleen" &&
                (event.evidence == .spleenInteraction || event.evidence == .observedSelection) &&
                event.observedAt <= now && now.timeIntervalSince(event.observedAt) <= ContextMemory.retention {
                selected[event.key] = max(selected[event.key] ?? .distantPast, event.observedAt)
            }
        }
        let savedKeys = Set(state.destinations.map(\.conversationKey))
        var merged = catalog.merged(with: state)
        merged.destinations += visits.entries.map(\.destination).filter { !savedKeys.contains($0.conversationKey) }
        let baseline = merged.results(query: "", now: now)
        let initial = baseline.map { item -> Row in
            let folder = item.provider == .codex ? metadata[item.threadID]?.folder : nil
            let project = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            let prose = item.title + " " + (item.provider == .codex ? notes[item.threadID]?.text ?? "" : "")
            let provider = item.provider == .claude && (try? ClaudeDesktopCodeTarget(conversationID: item.threadID)) != nil
                ? "Claude Code" : item.provider.displayName
            let selectedAt = state.rememberRecents
                ? [item.lastOpenedAt, selected[item.conversationKey]].compactMap { $0 }.filter { $0 <= now }.max() : nil
            return Row(destination: item, title: TextIndex.normalize(item.title), corpus: TextIndex.normalize(prose + " " + project + " " + provider), terms: TextIndex.terms(prose), folder: folder, visitedAt: visited[item.conversationKey], selectedAt: selectedAt, recordedSelectionAt: selected[item.conversationKey])
        }
        let hint = state.rememberRecents ? context.currentHint(at: now) : nil
        let matched = hint.flatMap { hint in initial.first { $0.destination.conversationKey == hint.key } }
        // An external selected chat may supply topic evidence without being an openable candidate.
        // Only absence of a fresh hint permits fallback to a prior Spleen selection.
        let recent = state.rememberRecents ? initial.filter {
            guard let opened = $0.destination.lastOpenedAt else { return false }
            return opened <= now && now.timeIntervalSince(opened) < ContextMemory.hintLifetime
        } : []
        let activeRow = matched ?? (hint == nil ? recent.max {
            ($0.destination.lastOpenedAt ?? .distantPast) < ($1.destination.lastOpenedAt ?? .distantPast)
        } : nil)
        let currentKey = hint?.key ?? activeRow?.destination.conversationKey
        self.currentKey = currentKey
        let previousKey = hint != nil ? context.previousDistinct(at: now)?.key : recent.filter {
            $0.destination.conversationKey != currentKey
        }.max {
            ($0.destination.lastOpenedAt ?? .distantPast) < ($1.destination.lastOpenedAt ?? .distantPast)
        }?.destination.conversationKey
        self.previousKey = previousKey
        let contextTerms = (activeRow?.terms ?? []).union(TextIndex.terms(hint?.topic ?? ""))
        func absoluteProject(_ value: String?) -> String? {
            guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        let contextFolder = absoluteProject(activeRow?.folder) ?? absoluteProject(hint?.project)
        var frequency: [String: Int] = [:]
        for row in initial { for term in row.terms { frequency[term, default: 0] += 1 } }
        func overlap(_ row: Row) -> Double {
            guard row.destination.conversationKey != currentKey else { return 0 }
            return row.terms.intersection(contextTerms).reduce(0.0) { $0 + log(1 + Double(initial.count) / Double(frequency[$1] ?? 1)) }
        }
        func score(_ row: Row) -> Double {
            let recentAt = [row.destination.lastOpenedAt, row.visitedAt, row.selectedAt].compactMap { $0 }.max()
            let recent = recentAt.map { max(0, 8 - max(0, now.timeIntervalSince($0)) / 86400) } ?? 0
            let project = contextFolder != nil && absoluteProject(row.folder) == contextFolder ? 10.0 : 0
            let previous = row.destination.conversationKey == previousKey ? Self.previousConversationBonus : 0
            return project + min(14, overlap(row) * 2) + recent + previous
        }
        let scores = initial.map(score)
        let liveAttention = initial.map { attention.liveState(for: $0.destination.conversationKey, at: now)?.needsAttention == true }
        func recentInteractionAt(_ index: Int) -> Date? {
            let row = initial[index]
            let interaction = row.destination.conversationKey == currentKey ? nil :
                [row.visitedAt, row.recordedSelectionAt].compactMap { $0 }.max()
            guard let date = [interaction, attention.recentActivityAt(for: row.destination.conversationKey, at: now)].compactMap({ $0 }).max(),
                  date <= now, now.timeIntervalSince(date) < ContextMemory.hintLifetime else { return nil }
            return date
        }
        func prefers(_ a: Int, _ b: Int) -> Bool {
            // Live provider evidence wins first. Recent explicit interactions
            // remain useful after a short activity lease expires; historical
            // unanswered text must not crowd them out during a silent turn.
            if liveAttention[a] != liveAttention[b] { return liveAttention[a] }
            let left = recentInteractionAt(a), right = recentInteractionAt(b)
            if (left != nil) != (right != nil) { return left != nil }
            if let left, let right {
                // Favor returning to the previous conversation within or across
                // apps, even if another task has slightly newer activity.
                // Eligibility still uses real timestamps and expires normally.
                let leftWeight = left.timeIntervalSinceReferenceDate +
                    (initial[a].destination.conversationKey == previousKey ? Self.previousRecencyAdvantage : 0)
                let rightWeight = right.timeIntervalSinceReferenceDate +
                    (initial[b].destination.conversationKey == previousKey ? Self.previousRecencyAdvantage : 0)
                if leftWeight != rightWeight { return leftWeight > rightWeight }
            }
            let aPriority = attention.priority(initial[a].destination, at: now)
            let bPriority = attention.priority(initial[b].destination, at: now)
            if aPriority != bPriority { return aPriority > bPriority }
            if scores[a] != scores[b] { return scores[a] > scores[b] }
            if initial[a].destination.pinned != initial[b].destination.pinned { return !initial[a].destination.pinned }
            return a < b
        }
        let eligible = initial.indices.filter { !attention.suppress(initial[$0].destination, at: now) }
        var sorted = eligible.sorted { a, b in
            // Last dispatch is only a selection hint: the user can switch inside
            // the provider. Live evidence or a recent interaction keeps it near
            // the center even when that hint still calls it current. This does
            // not keep an expired spinner alive. The center stays an alternative.
            let aCurrent = initial[a].destination.conversationKey == currentKey && !liveAttention[a] && recentInteractionAt(a) == nil
            let bCurrent = initial[b].destination.conversationKey == currentKey && !liveAttention[b] && recentInteractionAt(b) == nil
            if aCurrent != bCurrent { return !aCurrent }
            if initial[a].destination.pinned != initial[b].destination.pinned { return initial[a].destination.pinned }
            if initial[a].destination.pinned { return a < b }
            return prefers(a, b)
        }
        // The center recommends a different destination. Pins reserve nearby choices,
        // but do not override topic/history evidence or occupy the center by default.
        let alternatives = eligible.filter { initial[$0].destination.conversationKey != currentKey }
        let center = alternatives.min(by: prefers)
        if let center { sorted.removeAll { $0 == center }; sorted.insert(center, at: 0) }
        // Topic/history scores can fill every compass slot with older related chats.
        // Keep the latest catalog activity within reach, favoring another project
        // when context is known. Activity is not evidence of current attention.
        var latestActivity: Int?
        var latestOtherProjectActivity: Int?
        var latestUpdate = Date.distantPast
        var latestOtherProjectUpdate = Date.distantPast
        for index in sorted where initial[index].destination.conversationKey != currentKey {
            let item = initial[index].destination
            guard item.provider == .codex, let updated = metadata[item.threadID]?.updatedAt,
                  updated <= now else { continue }
            if updated > latestUpdate { latestActivity = index; latestUpdate = updated }
            if let contextFolder, let folder = absoluteProject(initial[index].folder), folder != contextFolder,
               updated > latestOtherProjectUpdate {
                latestOtherProjectActivity = index; latestOtherProjectUpdate = updated
            }
        }
        var activityAlternative: Int?
        let activityChoice = latestOtherProjectActivity ?? latestActivity
        if let activity = activityChoice,
           let position = sorted.firstIndex(of: activity), position >= 5,
           recentInteractionAt(sorted[4]) == nil, !liveAttention[sorted[4]], !initial[sorted[4]].destination.pinned {
            sorted.remove(at: position); sorted.insert(activity, at: 4)
            activityAlternative = activity
        }
        // Keep the newest observed Claude visit from the last day within reach.
        // The last observation is not continuous foreground tracking: returning
        // to Codex must not hide that Claude destination as supposedly current.
        // An older visible Claude pin does not stand in for this newest visit.
        var visitedAlternative: Int?
        if let candidate = sorted.filter({
               let row = initial[$0]
               guard row.destination.provider == .claude,
                     let visitedAt = row.visitedAt else { return false }
               return visitedAt <= now && now.timeIntervalSince(visitedAt) <= 86400
           }).max(by: { initial[$0].visitedAt! < initial[$1].visitedAt! }),
           let position = sorted.firstIndex(of: candidate), position >= 5,
           let slot = sorted.prefix(5).enumerated().reversed().first(where: {
               $0.offset > 0 && $0.element != activityChoice && !initial[$0.element].destination.pinned &&
                   !liveAttention[$0.element] && recentInteractionAt($0.element) == nil
           })?.offset {
            sorted.remove(at: position)
            let displaced = sorted.remove(at: slot)
            sorted.insert(candidate, at: slot)
            sorted.insert(displaced, at: 5)
            visitedAlternative = candidate
        }
        ordered = sorted.map { initial[$0].destination }
        // Explicit search retains settled destinations.
        rows = (sorted + initial.indices.filter { !eligible.contains($0) }).map { initial[$0] }
        previews = Dictionary(uniqueKeysWithValues: rows.map { row in
            let item = row.destination
            return (item.conversationKey, ConversationPreview(
                project: row.folder.map { URL(fileURLWithPath: $0).lastPathComponent },
                excerpt: item.provider == .codex ? notes[item.threadID]?.topic : nil,
                timing: item.provider == .codex ? notes[item.threadID]?.timing : nil,
                lastVisitedAt: row.visitedAt, lastSelectedAt: row.selectedAt))
        })
        let activityKey = activityAlternative.map { initial[$0].destination.conversationKey }
        let visitedKey = visitedAlternative.map { initial[$0].destination.conversationKey }
        subtitles = Dictionary(uniqueKeysWithValues: rows.map { row in
            let item = row.destination
            let project = row.folder.map { URL(fileURLWithPath: $0).lastPathComponent }
            let reason: String
            if item.pinned { reason = "Pinned" }
            else if item.conversationKey == visitedKey { reason = "Recently visited" }
            else if item.conversationKey == currentKey { reason = "Last selected" }
            else if item.conversationKey == activityKey { reason = "Latest activity" }
            else if item.conversationKey == previousKey { reason = "Previous conversation" }
            else if let selectedAt = row.selectedAt, now.timeIntervalSince(selectedAt) <= 1800 { reason = "Recently selected" }
            else if overlap(row) >= 1 { reason = "Related topic" }
            else if contextFolder != nil && absoluteProject(row.folder) == contextFolder { reason = "Same project" }
            else if row.visitedAt != nil && !savedKeys.contains(item.conversationKey) { reason = "Recently visited" }
            else { reason = item.lastOpenedAt != nil ? "Recently opened" : "Saved chat" }
            let provider = item.provider == .claude && (try? ClaudeDesktopCodeTarget(conversationID: item.threadID)) != nil
                ? "Claude Code · Experimental" : item.provider.displayName
            return (item.conversationKey, ([provider, reason] + (project.map { [$0] } ?? [])).joined(separator: " · "))
        })
    }
    public func results(query: String) -> [Destination] {
        let q = TextIndex.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return ordered }
        let tokens = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var buckets = [[Destination]](repeating: [], count: 4)
        for row in rows {
            if row.title == q { buckets[0].append(row.destination) }
            else if row.title.hasPrefix(q) { buckets[1].append(row.destination) }
            else if row.title.contains(q) { buckets[2].append(row.destination) }
            else if tokens.allSatisfy({ row.corpus.contains($0) }) { buckets[3].append(row.destination) }
        }
        return buckets.flatMap { $0 }
    }
}

/// Generations reject late builds. Presentation holds its own value until explicitly replaced.
public struct RelevancePipeline {
    public private(set) var generation = 0
    public private(set) var ready = RelevanceSnapshot.empty
    public init() {}
    public mutating func begin() -> Int { generation += 1; return generation }
    @discardableResult public mutating func finish(_ snapshot: RelevanceSnapshot, generation: Int) -> Bool {
        guard generation == self.generation else { return false }; ready = snapshot; return true
    }
}
