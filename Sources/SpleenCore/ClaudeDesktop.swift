import Foundation

public enum ClaudeChatTargetError: LocalizedError, Equatable {
    case invalidChatLink

    public var errorDescription: String? {
        "Use an existing Claude chat link: https://claude.ai/chat/<UUID> or claude://claude.ai/chat/<UUID>. Extra URL parameters aren't supported."
    }
}

/// A syntactically valid ordinary Claude chat destination, not proof of access or existence.
/// Accepts canonical web permalinks and Desktop links; emits only the Desktop scheme.
public struct ClaudeChatTarget: Equatable, Hashable, Sendable {
    public let id: String

    // Construction restricts id to the ASCII, hyphenated UUID format.
    public var url: URL { URL(string: "claude://claude.ai/chat/\(id)")! }

    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["claude://claude.ai/chat/", "https://claude.ai/chat/"]
        guard let prefix = prefixes.first(where: { raw.hasPrefix($0) }) else {
            throw ClaudeChatTargetError.invalidChatLink
        }
        let candidate = String(raw.dropFirst(prefix.count))
        // Validate the exact spelling before URL parsing can normalize or decode it.
        // This excludes encoded characters, credentials, ports, path additions,
        // queries (even an empty '?'), fragments, and non-chat routes.
        guard candidate.utf8.count == 36,
              let uuid = UUID(uuidString: candidate),
              uuid.uuidString.lowercased() == candidate.lowercased() else {
            throw ClaudeChatTargetError.invalidChatLink
        }
        id = uuid.uuidString.lowercased()
    }
}

public enum ClaudeDesktopCodeTargetError: LocalizedError, Equatable {
    case invalidSessionLink

    public var errorDescription: String? {
        "Use an existing Claude Desktop Code link: claude://claude.ai/epitaxy/local_<UUID>. Extra URL parameters aren't supported."
    }
}

/// Experimental existing-session route verified on an installed Claude Desktop build,
/// not a documented public API or proof that a particular session still exists.
/// Desktop local_ identities are separate from ordinary Chat and Code engine IDs.
public struct ClaudeDesktopCodeTarget: Equatable, Hashable, Sendable {
    private static let linkPrefix = "claude://claude.ai/epitaxy/local_"
    private static let identityPrefix = "desktop-code:local_"

    /// Canonical identity used by ClaudeDesktopObservation and saved destinations.
    public let id: String
    public var key: ConversationKey { ConversationKey(provider: .claude, id: id) }
    public var url: URL { URL(string: Self.linkPrefix + id.dropFirst(Self.identityPrefix.count))! }

    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix(Self.linkPrefix) else { throw ClaudeDesktopCodeTargetError.invalidSessionLink }
        id = Self.identityPrefix + (try Self.uuid(String(raw.dropFirst(Self.linkPrefix.count))))
    }

    /// Accepts only the namespaced observation identity; never infer a Desktop
    /// session from a bare UUID, an engine session ID, or an ordinary Chat key.
    public init(conversationID: String) throws {
        guard conversationID.hasPrefix(Self.identityPrefix) else { throw ClaudeDesktopCodeTargetError.invalidSessionLink }
        id = Self.identityPrefix + (try Self.uuid(String(conversationID.dropFirst(Self.identityPrefix.count))))
    }

    private static func uuid(_ value: String) throws -> String {
        // Validate raw spelling before URL parsing can decode or normalize it.
        guard value.utf8.count == 36, let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value.lowercased() else {
            throw ClaudeDesktopCodeTargetError.invalidSessionLink
        }
        return uuid.uuidString.lowercased()
    }
}
