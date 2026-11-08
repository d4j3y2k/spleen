import Foundation

public enum ConversationTimestampKind: Equatable {
    case reply, visit, selection, creation
}

public struct ConversationTimestamp: Equatable {
    public let kind: ConversationTimestampKind
    public let date: Date
    public let approximate: Bool

    public init(kind: ConversationTimestampKind, date: Date, approximate: Bool = false) {
        self.kind = kind; self.date = date; self.approximate = approximate
    }

    public func label(at now: Date) -> String? {
        guard date <= now else { return nil }
        let age = now.timeIntervalSince(date)
        let relative: String
        if age < 60 { relative = "just now" }
        else if age < 3600 { relative = "\(Int(age / 60))m ago" }
        else if age < 86400 { relative = "\(Int(age / 3600))h ago" }
        else { relative = "\(Int(age / 86400))d ago" }
        let prefix: String
        switch kind {
        case .reply: prefix = "Last reply"
        case .visit: prefix = "Last visited"
        case .selection: prefix = "Last selected"
        case .creation: prefix = "Created"
        }
        return "\(prefix) \(approximate ? "≈" : "")\(relative)"
    }

    public var help: String {
        if approximate { return "Approximate last reply time from Claude’s displayed message age: \(date.formatted(date: .abbreviated, time: .shortened)). Updates when this session is displayed in Claude." }
        let prefix: String
        switch kind {
        case .reply: prefix = "Last completed turn"
        case .visit: prefix = "Last observed visit"
        case .selection: prefix = "Last selected through Spleen"
        case .creation: prefix = "Session created"
        }
        return "\(prefix): \(date.formatted(date: .abbreviated, time: .standard))"
    }
}

/// Persisted turn timestamps. These do not establish live runtime state or user attention.
public struct TurnTiming: Codable, Equatable {
    public let lastStartedAt: Date?
    public let lastCompletedAt: Date?
    public let checkedAt: Date

    public init(lastStartedAt: Date? = nil, lastCompletedAt: Date? = nil, checkedAt: Date) {
        self.lastStartedAt = lastStartedAt
        self.lastCompletedAt = lastCompletedAt
        self.checkedAt = checkedAt
    }

    public func lastReplyLabel(at now: Date) -> String? {
        lastCompletedAt.flatMap { ConversationTimestamp(kind: .reply, date: $0).label(at: now) }
    }
}
