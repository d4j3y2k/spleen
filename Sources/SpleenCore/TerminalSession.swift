import Foundation
import CryptoKit

public enum TerminalHost: String, CaseIterable {
    case rex = "Rex", terminal = "Terminal", ghostty = "Ghostty"

    public var bundleID: String {
        switch self {
        case .rex: return "com.superlogical.rex"
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }
}

/// A route to a running CLI. The process birth time distinguishes reused PIDs and TTYs.
/// Runtime routes are carried on snapshot copies only and never encoded in saved destinations.
public struct TerminalSession: Equatable {
    public let host: TerminalHost
    public let provider: ContextProvider
    public let pid: Int32
    public let startMicroseconds: UInt64
    public let tty: String
    public let folder: String
    public let sessionID: UUID?
    public let title: String?

    public init(host: TerminalHost, provider: ContextProvider, pid: Int32, startMicroseconds: UInt64,
                tty: String, folder: String, sessionID: UUID?, title: String? = nil) {
        self.host = host; self.provider = provider; self.pid = pid; self.startMicroseconds = startMicroseconds
        self.tty = tty; self.folder = folder; self.sessionID = sessionID; self.title = title
    }
    public var startedAt: Date { Date(timeIntervalSince1970: Double(startMicroseconds) / 1_000_000) }
    public var providerLabel: String { provider == .claude ? "Claude Code" : "Codex" }
    public var key: ConversationKey {
        let id = sessionID?.uuidString.lowercased()
        if provider == .codex, let id { return ConversationKey(provider: provider, id: id) }
        return ConversationKey(provider: provider, id: "terminal:" + (id ?? "\(pid)-\(startMicroseconds)"))
    }
    /// A just-started CLI can publish its first thread ID after its card is displayed.
    /// Once a card names a thread, a different thread in the same process cannot satisfy it.
    public func matchesLiveRoute(_ live: Self) -> Bool {
        host == live.host && provider == live.provider && pid == live.pid && startMicroseconds == live.startMicroseconds
            && tty == live.tty && (sessionID == nil || sessionID == live.sessionID)
    }
    public var destination: Destination {
        let project = URL(fileURLWithPath: folder, isDirectory: true).lastPathComponent
        let fallback = [providerLabel, project, String(tty.dropFirst(5))].filter { !$0.isEmpty }.joined(separator: " · ")
        var item = Destination(id: provider == .codex ? sessionID ?? key.stableID : key.stableID,
                               title: title ?? fallback, threadID: key.id, provider: provider)
        item.terminal = self
        return item
    }

    public static func project(_ sessions: [Self], onto saved: SavedState, catalog: CatalogCache) -> SavedState {
        guard !sessions.isEmpty else { return saved }
        var result = saved
        var byKey = Dictionary(uniqueKeysWithValues: saved.destinations.indices.map { (saved.destinations[$0].conversationKey, $0) })
        let entries = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) })
        // Terminal discovery is an independent opt-in. Explicit exclusions still apply.
        var policy = catalog.effectivePolicy
        policy.scope = .automaticProjects
        let hidden = Set(catalog.hiddenIDs)
        for session in sessions where policy.allows(folder: session.folder, key: session.key) {
            let key = session.key
            guard key.provider != .codex || !hidden.contains(key.id) else { continue }
            if let i = byKey[key] {
                if result.destinations[i].terminal == nil { result.destinations[i].terminal = session }
            } else {
                var item = session.destination
                if key.provider == .codex, let entry = entries[key.id], catalog.includes(entry) { item.title = entry.title }
                byKey[key] = result.destinations.count
                result.destinations.append(item)
            }
        }
        return result
    }
}

extension ConversationKey {
    var stableID: UUID {
        var bytes = Array(SHA256.hash(data: Data((provider.rawValue + ":" + id).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
    }
}
