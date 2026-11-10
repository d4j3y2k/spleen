import Foundation

/// Claude exposes a rounded relative reply age, not an exact turn-completion time.
public struct ClaudeReplyTime: Codable, Equatable {
    public let date: Date
    public let uncertainty: TimeInterval
    public let observedAt: Date

    public init?(label: String, observedAt: Date) {
        guard label.count <= 40 else { return nil }
        let parts = label.split(separator: " ")
        let age: Double, unit: Double
        if label == "just now" { age = 0; unit = 60 }
        else {
            guard parts.count == 3, parts[2] == "ago", let count = Int(parts[0]), count > 0, count <= 30_000 else { return nil }
            switch parts[1] {
            case "second", "seconds": unit = 1
            case "minute", "minutes": unit = 60
            case "hour", "hours": unit = 3600
            case "day", "days": unit = 86400
            default: return nil
            }
            age = Double(count) * unit
        }
        guard age <= 30 * 86400 else { return nil }
        self.date = observedAt.addingTimeInterval(-age)
        self.uncertainty = unit
        self.observedAt = observedAt
    }

    public var isValid: Bool {
        date.timeIntervalSince1970.isFinite && observedAt.timeIntervalSince1970.isFinite &&
        date <= observedAt && observedAt.timeIntervalSince(date) <= 30 * 86400 &&
        [1.0, 60, 3600, 86400].contains(uncertainty)
    }
}

/// Historical display metadata only; never establishes visits, completion or attention.
public struct ClaudeReplyTimes: Codable, Equatable {
    private struct Entry: Codable, Equatable { let key: ConversationKey; let time: ClaudeReplyTime }
    private var entries: [Entry] = []
    public init() {}
    public func time(for key: ConversationKey, at now: Date) -> ClaudeReplyTime? {
        entries.first { $0.key == key && $0.time.observedAt <= now && now.timeIntervalSince($0.time.observedAt) < 30 * 86400 }?.time
    }
    @discardableResult public mutating func record(_ time: ClaudeReplyTime, for key: ConversationKey, now: Date) -> Bool {
        guard key.provider == .claude, (try? ClaudeDesktopCodeTarget(conversationID: key.id)) != nil,
              time.isValid, time.observedAt <= now, now.timeIntervalSince(time.observedAt) < 8 else { return false }
        // Repeated reads of a rounded label must not move the reply forward on
        // every poll. Only a clearly newer estimate replaces retained evidence.
        if let prior = self.time(for: key, at: now) {
            let sameDisplayedAge = time.uncertainty == prior.uncertainty &&
                time.observedAt.timeIntervalSince(time.date) == prior.observedAt.timeIntervalSince(prior.date)
            if sameDisplayedAge || time.date.timeIntervalSince(prior.date) <= max(time.uncertainty, prior.uncertainty) { return false }
        }
        entries.removeAll { $0.key == key || now.timeIntervalSince($0.time.observedAt) >= 30 * 86400 || $0.time.observedAt > now }
        entries.append(Entry(key: key, time: time))
        entries = Array(entries.suffix(256))
        return true
    }
    public func save(to url: URL) throws {
        try PrivateFile.write(JSONEncoder().encode(self), to: url)
    }
    public static func load(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000 else { throw SpleenError.invalidStore }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.entries.count <= 256, Set(result.entries.map(\.key)).count == result.entries.count,
              result.entries.allSatisfy({ $0.time.isValid && $0.key.provider == .claude &&
                  (try? ClaudeDesktopCodeTarget(conversationID: $0.key.id)) != nil }) else { throw SpleenError.invalidStore }
        return result
    }
}
