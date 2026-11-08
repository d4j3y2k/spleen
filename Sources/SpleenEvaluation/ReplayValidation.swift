import Foundation
import SpleenCore

extension RankingReplay {
    static func validate(_ suite: ReplaySuite) throws {
        guard suite.version == 1 else { throw ReplayError.unsupportedVersion }
        guard (1...32).contains(suite.cases.count) else { throw ReplayError.limitExceeded }
        var entries = 0, bytes = 0
        func text(_ value: String, limit: Int) throws {
            guard value.utf8.count <= limit, !value.contains("\0") else { throw ReplayError.invalidEvidence }
            bytes += value.utf8.count
            guard bytes <= maximumInputBytes else { throw ReplayError.limitExceeded }
        }
        func date(_ value: Date, before: Date) throws {
            let number = value.timeIntervalSince1970
            guard number.isFinite, (0...4_102_444_800).contains(number), value <= before else { throw ReplayError.invalidEvidence }
        }
        func path(_ value: String) throws {
            try text(value, limit: 4096)
            guard value.hasPrefix("/"), value.rangeOfCharacter(from: .controlCharacters) == nil else { throw ReplayError.invalidEvidence }
        }
        func key(_ value: ConversationKey) throws {
            try text(value.id, limit: 512)
            let valid: Bool
            if value.provider == .codex { valid = (try? ThreadTarget(value.id).id) == value.id }
            else if value.id.hasPrefix("desktop-code:") {
                valid = value.id.range(of: "^desktop-code:local_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
            } else { valid = (try? ClaudeChatTarget("claude://claude.ai/chat/\(value.id)").id) == value.id }
            guard valid else { throw ReplayError.invalidEvidence }
        }
        func evidence(_ value: ReplayEvidence, at time: Double, anchor: Date) throws {
            let moment = anchor.addingTimeInterval(time)
            guard value.anchorDate == anchor else { throw ReplayError.invalidEvidence }
            try date(anchor, before: moment)
            guard value.state.destinations.count <= 1000, value.catalog.entries.count <= 1000,
                  value.notes.count <= 1000, value.contextEvents.count <= 64,
                  value.catalog.folders.count <= 10, value.catalog.hiddenIDs.count <= 1000,
                  (1...2).contains(value.catalog.version) else { throw ReplayError.limitExceeded }
            entries += value.state.destinations.count + value.catalog.entries.count + value.notes.count + value.contextEvents.count
            guard entries <= 10_000 else { throw ReplayError.limitExceeded }
            do { try value.state.validate() } catch { throw ReplayError.invalidEvidence }
            for item in value.state.destinations {
                try text(item.title, limit: 1024); try key(item.conversationKey)
                if let selected = item.lastOpenedAt { try date(selected, before: moment) }
            }
            guard Set(value.catalog.entries.map(\.id)).count == value.catalog.entries.count,
                  Set(value.notes.map(\.id)).count == value.notes.count else { throw ReplayError.invalidEvidence }
            var available = Set(value.state.destinations.map(\.conversationKey))
            for item in value.catalog.entries {
                let identity = ConversationKey(provider: .codex, id: item.id)
                try key(identity); try text(item.title, limit: 1024); try path(item.folder); try date(item.updatedAt, before: moment)
                guard !item.title.isEmpty, value.catalog.includes(item) else { throw ReplayError.invalidEvidence }
                available.insert(identity)
            }
            guard available.count <= 1000 else { throw ReplayError.limitExceeded }
            for folder in value.catalog.folders { try path(folder) }
            for id in value.catalog.hiddenIDs { try key(ConversationKey(provider: .codex, id: id)) }
            if let refreshed = value.catalog.refreshedAt { try date(refreshed, before: moment) }
            let policy = value.catalog.effectivePolicy
            guard policy.folders.count <= 1000, policy.excludedFolders.count <= 1000,
                  policy.excludedConversationIDs.count <= 1000, (1...100).contains(policy.pageSize),
                  (1...10).contains(policy.maxPages), policy.cacheTTL.isFinite, (30...86400).contains(policy.cacheTTL)
            else { throw ReplayError.limitExceeded }
            for folder in policy.folders + policy.excludedFolders { try path(folder) }
            for identity in policy.excludedConversationIDs { try key(identity) }
            for note in value.notes {
                try key(ConversationKey(provider: .codex, id: note.id)); try path(note.folder); try date(note.updatedAt, before: moment)
                for part in [note.topic, note.decision, note.nextStep] {
                    try text(part, limit: 1120)
                    guard part.count <= 280 else { throw ReplayError.invalidEvidence }
                }
            }
            for event in value.contextEvents {
                try key(event.key); try date(event.observedAt, before: moment); try text(event.source, limit: 256)
                guard !event.source.isEmpty else { throw ReplayError.invalidEvidence }
                if let project = event.project { try path(project) }
                if let topic = event.topic {
                    try text(topic, limit: 1120)
                    guard topic.count <= 280 else { throw ReplayError.invalidEvidence }
                }
            }
        }
        func time(_ value: Double) -> Bool { value.isFinite && (0...86400).contains(value) }
        for item in suite.cases {
            guard item.attempts.count <= 8, (1...32).contains(item.opens.count) else { throw ReplayError.limitExceeded }
            try evidence(item.evidence, at: 0, anchor: item.evidence.anchorDate)
            var previousAttempt = -1.0, previousClose = -1.0
            for attempt in item.attempts {
                guard time(attempt.at), attempt.at >= previousAttempt, time(attempt.validationDelay) else { throw ReplayError.invalidTimeline }
                previousAttempt = attempt.at
                if let delay = attempt.responseAfter {
                    guard attempt.response.kind != .missing, time(delay), time(attempt.at + delay + attempt.validationDelay) else { throw ReplayError.invalidTimeline }
                } else {
                    guard attempt.response.kind == .missing, attempt.validationDelay == 0 else { throw ReplayError.invalidTimeline }
                }
                if let replacement = attempt.evidence { try evidence(replacement, at: attempt.at, anchor: item.evidence.anchorDate) }
                if attempt.response.kind == .choice {
                    guard let index = attempt.response.choiceIndex, (0..<8).contains(index) else { throw ReplayError.invalidResponseRecipe }
                } else if attempt.response.choiceIndex != nil { throw ReplayError.invalidResponseRecipe }
                if attempt.response.kind == .raw {
                    guard let raw = attempt.response.rawJSON, raw.utf8.count <= maximumResponseBytes else { throw ReplayError.limitExceeded }
                    bytes += raw.utf8.count
                    guard bytes <= maximumInputBytes else { throw ReplayError.limitExceeded }
                } else if attempt.response.rawJSON != nil { throw ReplayError.invalidResponseRecipe }
            }
            for opening in item.opens {
                guard time(opening.at), time(opening.closeAt), opening.at < opening.closeAt,
                      opening.at >= previousClose else { throw ReplayError.invalidTimeline }
                previousClose = opening.closeAt
                if let target = opening.target { try key(target) }
            }
        }
    }
}
