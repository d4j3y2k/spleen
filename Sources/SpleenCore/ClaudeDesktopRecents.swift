import Foundation
import CryptoKit

/// A bounded projection of visited Desktop Code and Chat sessions, not a complete provider catalog.
/// Only foreground selections from the opt-in observer qualify; lifecycle and dispatch do not.
public struct ClaudeDesktopRecents: Equatable {
    public struct Entry: Equatable {
        public let destination: Destination
        public let observedAt: Date
    }
    public let entries: [Entry]
    public var expiresAt: Date? { entries.map { $0.observedAt.addingTimeInterval(ContextMemory.retention) }.min() }

    private static func observation(for id: String, title: String) -> ClaudeDesktopObservation? {
        if let target = try? ClaudeDesktopCodeTarget(conversationID: id) {
            return ClaudeDesktopObservation(url: "https://claude.ai/epitaxy/" + target.id.dropFirst("desktop-code:".count), title: title + " - Claude Code")
        }
        return ClaudeDesktopObservation(url: "https://claude.ai/chat/" + id, title: title + " - Claude")
    }

    public init(_ memory: ContextMemory, excluding: [ConversationKey] = [], now: Date = Date()) {
        guard memory.recentsEnabled else { entries = []; return }
        let excluded = Set(excluding)
        var latest: [ConversationKey: ContextHint] = [:]
        var titles: [ConversationKey: String] = [:]
        for event in memory.observedSelections(at: now).sorted(by: { $0.observedAt < $1.observedAt }) {
            guard event.key.provider == .claude,
                  event.evidence == .observedSelection,
                  event.source == "claude-desktop-accessibility",
                  event.observedAt <= now, now.timeIntervalSince(event.observedAt) <= ContextMemory.retention,
                  let observation = Self.observation(for: event.key.id, title: event.topic ?? ""),
                  !excluded.contains(observation.key) else { continue }
            latest[observation.key] = event
            if let raw = event.topic, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let title = Self.observation(for: event.key.id, title: raw)?.title,
               !title.isEmpty { titles[observation.key] = title }
        }
        entries = latest.map { key, event in
            // Include provider and namespace in the stable identifier. A bare UUID suffix
            // can also be a Codex ID or ordinary Chat ID and must not alias either.
            var bytes = Array(SHA256.hash(data: Data((key.provider.rawValue + ":" + key.id).utf8)).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x80
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let id = UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))")!
            return Entry(destination: Destination(id: id, title: titles[key] ?? "Claude \(key.id.hasPrefix("desktop-code:") ? "Code" : "Chat") · \(key.id.suffix(8))",
                                                  threadID: key.id, provider: .claude), observedAt: event.observedAt)
        }.sorted { $0.observedAt == $1.observedAt ? $0.destination.threadID < $1.destination.threadID : $0.observedAt > $1.observedAt }
    }
}
