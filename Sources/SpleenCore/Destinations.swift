import Foundation

public enum SpleenError: LocalizedError {
    case invalidLink, invalidDotLink, emptyTitle, duplicate, tooManyPins, invalidSettings, invalidStore
    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "Use an existing Codex, Claude Chat, or Claude Desktop Code link. New-session links and extra URL parameters aren't supported."
        case .invalidDotLink: return "Paste your Dot’s Codex chat link. Only an existing thread and its optional hostId are supported."
        case .emptyTitle: return "Give this destination a title."
        case .duplicate: return "That chat is already saved. Edit its existing destination instead."
        case .tooManyPins: return "You can pin up to two destinations. Unpin one first."
        case .invalidSettings: return "Choose a key and at least one of Control, Option, or Command."
        case .invalidStore: return "The saved file is invalid or from a newer version. It has been preserved; move it aside or repair it before saving."
        }
    }
}

/// A separate, user-configured shortcut outside the ranked local conversation list.
/// Cloud Dot links need their hostId preserved when opening the existing thread.
public struct DotTarget: Equatable {
    public let url: URL
    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw), components.scheme == "codex",
              components.query == nil || components.queryItems?.count == 1 else { throw SpleenError.invalidDotLink }
        let host = components.queryItems?.first
        if let host {
            guard host.name == "hostId", let value = host.value, value.count <= 128,
                  value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
                throw SpleenError.invalidDotLink
            }
        }
        components.query = nil
        guard let bareURL = components.url, let target = try? ThreadTarget(bareURL.absoluteString) else {
            throw SpleenError.invalidDotLink
        }
        var canonical = URLComponents(url: target.url, resolvingAgainstBaseURL: false)!
        if let host { canonical.queryItems = [host] }
        url = canonical.url!
    }
}

public struct ThreadTarget: Equatable {
    public let id: String
    public var url: URL { URL(string: "codex://threads/\(id)")! }
    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if raw.contains("://") {
            guard let c = URLComponents(string: raw), c.scheme == "codex", c.host == "threads",
                  c.user == nil, c.password == nil, c.port == nil, c.query == nil, c.fragment == nil,
                  c.percentEncodedPath == c.path, c.path.hasPrefix("/") else { throw SpleenError.invalidLink }
            candidate = String(c.path.dropFirst())
        } else { candidate = raw }
        // IDs are opaque; accept current UUIDs and protocol-style IDs, never routes or path syntax.
        guard candidate.count >= 8, candidate.count <= 128,
              candidate.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              candidate.lowercased() != "new" else { throw SpleenError.invalidLink }
        id = candidate
    }
}

public struct Destination: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var threadID: String
    public var pinned: Bool
    public var lastOpenedAt: Date?
    public var provider: ContextProvider
    /// True for a discovered chat saved because it was opened: it shows Codex's current
    /// title. False for a title typed in the editor. Nil for entries saved before this was
    /// recorded, until `SavedState.adoptCatalogTitles` can tell.
    public var followsCatalogTitle: Bool?
    public var conversationKey: ConversationKey { ConversationKey(provider: provider, id: threadID) }
    public var navigationURL: URL {
        get throws {
            switch provider {
            case .codex: return try ThreadTarget(threadID).url
            case .claude:
                if threadID.hasPrefix("desktop-code:") { return try ClaudeDesktopCodeTarget(conversationID: threadID).url }
                return try ClaudeChatTarget("claude://claude.ai/chat/\(threadID)").url
            }
        }
    }
    public init(id: UUID = UUID(), title: String, threadID: String, pinned: Bool = false, lastOpenedAt: Date? = nil, provider: ContextProvider = .codex,
                followsCatalogTitle: Bool? = nil) {
        self.id = id; self.title = title; self.threadID = threadID; self.pinned = pinned; self.lastOpenedAt = lastOpenedAt; self.provider = provider
        self.followsCatalogTitle = followsCatalogTitle
    }
    private enum CodingKeys: String, CodingKey { case id, title, threadID, pinned, lastOpenedAt, provider, followsCatalogTitle }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        title = try fields.decode(String.self, forKey: .title)
        threadID = try fields.decode(String.self, forKey: .threadID)
        pinned = try fields.decode(Bool.self, forKey: .pinned)
        lastOpenedAt = try fields.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        provider = try fields.decodeIfPresent(ContextProvider.self, forKey: .provider) ?? .codex
        followsCatalogTitle = try fields.decodeIfPresent(Bool.self, forKey: .followsCatalogTitle)
    }
    /// Whether the title follows Codex is bookkeeping about the title, not part of what the
    /// destination is: the same chat compares equal before and after that is recorded.
    public static func == (a: Destination, b: Destination) -> Bool {
        a.id == b.id && a.title == b.title && a.threadID == b.threadID && a.pinned == b.pinned &&
            a.lastOpenedAt == b.lastOpenedAt && a.provider == b.provider
    }
}

public struct Shortcut: Codable, Equatable {
    public var key: String
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool
    public init(key: String = "Space", control: Bool = true, option: Bool = true, command: Bool = false, shift: Bool = false) {
        self.key = key; self.control = control; self.option = option; self.command = command; self.shift = shift
    }
    public static let keys = ["Space", "S", "K", "P"]
    public var isValid: Bool { Self.keys.contains(key) && (control || option || command) }
    public var label: String { (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key }
}

public struct SavedState: Codable, Equatable {
    public var version = 1
    public var destinations: [Destination] = []
    public var shortcut = Shortcut()
    public var rememberRecents = true
    public var recentHistoryClearedAt: Date?
    public var dotLink: String?
    public init() {}
    public func validate() throws {
        guard (1...3).contains(version), shortcut.isValid,
              Set(destinations.map(\.id)).count == destinations.count,
              Set(destinations.map(\.conversationKey)).count == destinations.count,
              destinations.filter(\.pinned).count <= 2 else { throw SpleenError.invalidStore }
        if let dotLink, (try? DotTarget(dotLink)) == nil { throw SpleenError.invalidStore }
        for item in destinations {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? item.navigationURL) != nil else { throw SpleenError.invalidStore }
            if item.provider == .codex {
                guard (try? ThreadTarget(item.threadID).id) == item.threadID else { throw SpleenError.invalidStore }
            } else if item.threadID.hasPrefix("desktop-code:") {
                guard version >= 3, (try? ClaudeDesktopCodeTarget(conversationID: item.threadID).id) == item.threadID else { throw SpleenError.invalidStore }
            } else {
                guard (try? ClaudeChatTarget("claude://claude.ai/chat/\(item.threadID)").id) == item.threadID else { throw SpleenError.invalidStore }
            }
        }
    }
    public mutating func upsert(id: UUID?, title: String, link: String, pinned: Bool) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SpleenError.emptyTitle }
        let targetID: String, provider: ContextProvider
        if let target = try? ClaudeDesktopCodeTarget(link) {
            targetID = target.id; provider = .claude
        } else if link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("claude:") || link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https:") {
            targetID = try ClaudeChatTarget(link).id; provider = .claude
        } else { targetID = try ThreadTarget(link).id; provider = .codex }
        let key = ConversationKey(provider: provider, id: targetID)
        guard !destinations.contains(where: { $0.conversationKey == key && $0.id != id }) else { throw SpleenError.duplicate }
        guard !pinned || destinations.filter({ $0.pinned && $0.id != id }).count < 2 else { throw SpleenError.tooManyPins }
        if let id, let i = destinations.firstIndex(where: { $0.id == id }) {
            if destinations[i].conversationKey != key { destinations[i].lastOpenedAt = nil }
            // A title typed here is a label to keep; an unchanged one keeps following Codex.
            if destinations[i].title != title || destinations[i].conversationKey != key { destinations[i].followsCatalogTitle = false }
            destinations[i].title = title; destinations[i].threadID = targetID; destinations[i].provider = provider; destinations[i].pinned = pinned
        } else { destinations.append(Destination(title: title, threadID: targetID, pinned: pinned, provider: provider, followsCatalogTitle: false)) }
        if provider == .claude { version = max(version, targetID.hasPrefix("desktop-code:") ? 3 : 2) }
    }
    public mutating func remove(_ id: UUID) { destinations.removeAll { $0.id == id } }
    public mutating func recordDispatch(_ id: UUID, at date: Date = Date()) {
        guard rememberRecents, let i = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[i].lastOpenedAt = date
    }
    /// Codex's generated titles, which nobody types as a label.
    static func isPlaceholderTitle(_ title: String) -> Bool {
        title.hasPrefix("Untitled chat · ") || title.hasPrefix("Codex · ")
    }
    /// Discovered chats saved because they were opened show Codex's current title, so a
    /// rename in Codex appears here too; a title typed in the editor is kept. Entries saved
    /// before that was recorded follow only when nothing suggests a label: created from the
    /// catalog, and still matching it or a generated placeholder. Returns whether anything changed.
    public mutating func adoptCatalogTitles(from catalog: CatalogCache) -> Bool {
        let entries = Dictionary(catalog.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for i in destinations.indices where destinations[i].provider == .codex {
            guard let entry = entries[destinations[i].threadID] else { continue }
            if destinations[i].followsCatalogTitle == nil {
                destinations[i].followsCatalogTitle = destinations[i].id == entry.destination.id &&
                    (destinations[i].title == entry.title || Self.isPlaceholderTitle(destinations[i].title))
                changed = true
            }
            if destinations[i].followsCatalogTitle == true, destinations[i].title != entry.title,
               !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                destinations[i].title = entry.title; changed = true
            }
        }
        return changed
    }
    public mutating func clearRecents(at date: Date = Date()) {
        recentHistoryClearedAt = date
        // Chats saved only because they were opened are navigation history too.
        destinations.removeAll { $0.followsCatalogTitle == true && !$0.pinned }
        for i in destinations.indices { destinations[i].lastOpenedAt = nil }
    }
    public func results(query: String, now: Date = Date()) -> [Destination] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        func match(_ title: String) -> Int {
            let t = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if t == q { return 0 }; if t.hasPrefix(q) { return 1 }; if t.contains(q) { return 2 }; return 3
        }
        return destinations.enumerated().filter { q.isEmpty || match($0.element.title) < 3 }.sorted { a, b in
            if !q.isEmpty {
                let x = match(a.element.title), y = match(b.element.title)
                return x == y ? a.offset < b.offset : x < y
            }
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            if a.element.pinned { return a.offset < b.offset }
            let cutoff = now.addingTimeInterval(-30 * 86400)
            let x = a.element.lastOpenedAt.flatMap { $0 >= cutoff ? $0 : nil } ?? .distantPast
            let y = b.element.lastOpenedAt.flatMap { $0 >= cutoff ? $0 : nil } ?? .distantPast
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }
}

public final class StateRepository {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
        let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
        try state.validate()
        return state
    }
    public func save(_ state: SavedState) throws {
        try state.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(encoder.encode(state), to: url)
    }
}

public enum DismissReason { case cancel, focusLoss, dispatch }
public struct PanelSession {
    public private(set) var isPresented = false
    public private(set) var priorPID: Int32?
    public init() {}
    public mutating func present(priorPID: Int32?) { self.priorPID = priorPID; isPresented = true }
    public mutating func dismiss(_ reason: DismissReason, currentPID: Int32?, ownPID: Int32) -> Int32? {
        guard isPresented else { return nil }
        isPresented = false
        defer { priorPID = nil }
        guard reason == .cancel, let priorPID, priorPID != ownPID,
              currentPID == ownPID || currentPID == priorPID else { return nil }
        return priorPID
    }
}
